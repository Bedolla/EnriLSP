import { spawn, type ChildProcess } from "node:child_process";
import { readFile } from "node:fs/promises";
import { extname, isAbsolute, join, normalize, relative, resolve } from "node:path";

import type {
  EnriLspConfig,
  EnriLspServerConfig,
  LspDiagnostic,
  LspId,
  LspLocation,
  LspLocationLink,
  LspMessage,
  LspPosition,
  LspWorkspaceEdit,
  SymbolMatch,
} from "../types.js";
import { pathToUri, uriToPath } from "./utils.js";

interface DocumentSymbol {
  name: string;
  kind: number;
  range: { start: LspPosition; end: LspPosition };
  selectionRange: { start: LspPosition; end: LspPosition };
  children?: DocumentSymbol[];
}

interface SymbolInformation {
  name: string;
  kind: number;
  location: LspLocation;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason?: unknown) => void;
  timer: NodeJS.Timeout;
}

interface ServerState {
  process: ChildProcess;
  config: EnriLspServerConfig;
  initialized: boolean;
  initializationPromise: Promise<void>;
  initializationResolve: () => void;
  openFiles: Set<string>;
  fileVersions: Map<string, number>;
  diagnostics: Map<string, LspDiagnostic[]>;
  buffer: Buffer;
  workspaceRoot: string;
}

export class LspClient {
  private config: EnriLspConfig;

  private servers = new Map<string, ServerState>();
  private serversStarting = new Map<string, Promise<ServerState>>();

  private nextId = 1;
  private pendingRequests = new Map<LspId, PendingRequest>();

  constructor(config: EnriLspConfig) {
    this.config = config;
  }

  symbolKindToString(kind: number): string {
    const map: Record<number, string> = {
      1: "file",
      2: "module",
      3: "namespace",
      4: "package",
      5: "class",
      6: "method",
      7: "property",
      8: "field",
      9: "constructor",
      10: "enum",
      11: "interface",
      12: "function",
      13: "variable",
      14: "constant",
      15: "string",
      16: "number",
      17: "boolean",
      18: "array",
      19: "object",
      20: "key",
      21: "null",
      22: "enumMember",
      23: "struct",
      24: "event",
      25: "operator",
      26: "typeParameter",
    };

    return map[kind] ?? `unknown(${kind})`;
  }

  symbolKindFromString(kind?: string): number | undefined {
    if (!kind) return undefined;
    const normalized = kind.trim().toLowerCase();
    const map: Record<string, number> = {
      file: 1,
      module: 2,
      namespace: 3,
      package: 4,
      class: 5,
      method: 6,
      property: 7,
      field: 8,
      constructor: 9,
      enum: 10,
      interface: 11,
      function: 12,
      variable: 13,
      constant: 14,
      string: 15,
      number: 16,
      boolean: 17,
      array: 18,
      object: 19,
      key: 20,
      null: 21,
      enummember: 22,
      "enum-member": 22,
      struct: 23,
      event: 24,
      operator: 25,
      typeparameter: 26,
      "type-parameter": 26,
    };
    return map[normalized];
  }

  private getLanguageId(filePath: string): string {
    const ext = extname(filePath).toLowerCase().replace(/^\./, "");
    const map: Record<string, string> = {
      cs: "csharp",
      csx: "csharp",
      ts: "typescript",
      tsx: "typescriptreact",
      js: "javascript",
      jsx: "javascriptreact",
      py: "python",
      go: "go",
      rs: "rust",
      java: "java",
      kt: "kotlin",
      kts: "kotlin",
      php: "php",
      rb: "ruby",
      lua: "lua",
      cpp: "cpp",
      c: "c",
      h: "c",
      hpp: "cpp",
      json: "json",
      yaml: "yaml",
      yml: "yaml",
      md: "markdown",
    };
    return (map[ext] ?? ext) || "plaintext";
  }

  private getServerForFile(filePath: string): EnriLspServerConfig | null {
    const ext = extname(filePath).toLowerCase().replace(/^\./, "");
    if (!ext) return null;

    const matching = this.config.servers.filter((s) =>
      s.extensions.map((e) => e.toLowerCase()).includes(ext)
    );
    if (matching.length === 0) return null;
    if (matching.length === 1) return matching[0] ?? null;

    const absoluteFilePath = normalize(
      isAbsolute(filePath) ? filePath : resolve(process.cwd(), filePath)
    );

    let best: EnriLspServerConfig | null = null;
    let bestLen = -1;

    for (const server of matching) {
      const root = normalize(
        isAbsolute(server.rootDir ?? "")
          ? (server.rootDir as string)
          : resolve(process.cwd(), server.rootDir ?? ".")
      );

      const rel = relative(root, absoluteFilePath);
      const isInside = rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
      if (isInside && root.length > bestLen) {
        bestLen = root.length;
        best = server;
      }
    }

    return best ?? matching[0] ?? null;
  }

  private makeServerKey(server: EnriLspServerConfig): string {
    const root = normalize(
      isAbsolute(server.rootDir ?? "")
        ? (server.rootDir as string)
        : resolve(process.cwd(), server.rootDir ?? ".")
    );

    return JSON.stringify({
      command: server.command,
      rootDir: root,
      extensions: server.extensions,
    });
  }

  private async getServer(filePath: string): Promise<ServerState> {
    const serverConfig = this.getServerForFile(filePath);
    if (!serverConfig) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }

    const key = this.makeServerKey(serverConfig);
    const existing = this.servers.get(key);
    if (existing) return existing;

    const starting = this.serversStarting.get(key);
    if (starting) return starting;

    const startPromise = this.startServer(serverConfig);
    this.serversStarting.set(key, startPromise);

    try {
      const state = await startPromise;
      this.servers.set(key, state);
      this.serversStarting.delete(key);
      return state;
    } catch (error) {
      this.serversStarting.delete(key);
      throw error;
    }
  }

  private async startServer(serverConfig: EnriLspServerConfig): Promise<ServerState> {
    const command = serverConfig.command[0];
    if (!command) {
      throw new Error("Invalid server config: command[0] is required");
    }

    const args = serverConfig.command.slice(1);
    const workspaceRoot = normalize(
      isAbsolute(serverConfig.rootDir ?? "")
        ? (serverConfig.rootDir as string)
        : resolve(process.cwd(), serverConfig.rootDir ?? ".")
    );

    const child = spawn(command, args, {
      cwd: workspaceRoot,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      shell: process.platform === "win32",
    });

    let initializationResolve!: () => void;
    const initializationPromise = new Promise<void>((resolve) => {
      initializationResolve = resolve;
    });

    const state: ServerState = {
      process: child,
      config: serverConfig,
      initialized: false,
      initializationPromise,
      initializationResolve,
      openFiles: new Set(),
      fileVersions: new Map(),
      diagnostics: new Map(),
      buffer: Buffer.alloc(0),
      workspaceRoot,
    };

    child.stdout?.on("data", (chunk: Buffer) => {
      state.buffer = Buffer.concat([state.buffer, chunk]);
      this.drainServerBuffer(state);
    });

    child.stderr?.on("data", (data: Buffer) => {
      process.stderr.write(data);
    });

    child.on("exit", (code, signal) => {
      process.stderr.write(
        `[enrilsp] LSP server exited: ${serverConfig.command.join(" ")} (code=${code}, signal=${signal})\n`
      );

      // Drop from caches so a future request can restart it.
      const key = this.makeServerKey(serverConfig);
      this.servers.delete(key);
      this.serversStarting.delete(key);
    });

    await this.initializeServer(state);
    return state;
  }

  private drainServerBuffer(state: ServerState): void {
    const separator = Buffer.from("\r\n\r\n", "ascii");

    while (true) {
      const headerEnd = state.buffer.indexOf(separator);
      if (headerEnd === -1) return;

      const headerText = state.buffer.slice(0, headerEnd).toString("ascii");
      const match = /Content-Length:\s*(\d+)/i.exec(headerText);
      if (!match?.[1]) {
        // Skip invalid header.
        state.buffer = state.buffer.slice(headerEnd + separator.length);
        continue;
      }

      const length = Number.parseInt(match[1], 10);
      const bodyStart = headerEnd + separator.length;
      if (state.buffer.length < bodyStart + length) return;

      const body = state.buffer.slice(bodyStart, bodyStart + length);
      state.buffer = state.buffer.slice(bodyStart + length);

      try {
        const message = JSON.parse(body.toString("utf8")) as LspMessage;
        this.handleMessage(message, state);
      } catch (error) {
        process.stderr.write(`[enrilsp] Failed to parse LSP message: ${error}\n`);
      }
    }
  }

  private async initializeServer(state: ServerState): Promise<void> {
    const rootUri = pathToUri(state.workspaceRoot);

    const initializeParams: Record<string, unknown> = {
      processId: state.process.pid ?? null,
      clientInfo: { name: "enrilsp", version: "0.1.0" },
      capabilities: {
        window: { workDoneProgress: true },
        workspace: {
          configuration: true,
          workspaceFolders: true,
          workspaceEdit: { documentChanges: true },
        },
        textDocument: {
          synchronization: { didOpen: true, didChange: true, didClose: true },
          definition: { linkSupport: false },
          references: { includeDeclaration: true },
          rename: { prepareSupport: false },
          documentSymbol: {
            hierarchicalDocumentSymbolSupport: true,
            symbolKind: {
              valueSet: [
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
                22, 23, 24, 25, 26,
              ],
            },
          },
          hover: {},
          completion: { completionItem: { snippetSupport: true } },
        },
      },
      rootUri,
      workspaceFolders: [{ uri: rootUri, name: "workspace" }],
    };

    if (state.config.initializationOptions !== undefined) {
      initializeParams.initializationOptions = state.config.initializationOptions;
    }

    await this.sendRequest(state.process, "initialize", initializeParams, 30_000);
    this.sendNotification(state.process, "initialized", {});

    state.initialized = true;
    state.initializationResolve();

    const warmupMs = state.config.warmupMs ?? 0;
    if (warmupMs > 0) {
      await new Promise((r) => setTimeout(r, warmupMs));
    }
  }

  private sendMessage(process: ChildProcess, message: LspMessage): void {
    const content = JSON.stringify(message);
    const header = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n`;
    process.stdin?.write(header, "ascii");
    process.stdin?.write(content, "utf8");
  }

  private sendRequest(
    process: ChildProcess,
    method: string,
    params: unknown,
    timeoutMs: number
  ): Promise<unknown> {
    const id = this.nextId++;
    const message: LspMessage = { jsonrpc: "2.0", id, method, params };

    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.pendingRequests.delete(id);
        rejectPromise(new Error(`LSP request timeout: ${method} (${timeoutMs}ms)`));
      }, timeoutMs);

      this.pendingRequests.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolvePromise(value);
        },
        reject: (reason) => {
          clearTimeout(timer);
          rejectPromise(reason);
        },
        timer,
      });

      this.sendMessage(process, message);
    });
  }

  private sendNotification(process: ChildProcess, method: string, params: unknown): void {
    const message: LspMessage = { jsonrpc: "2.0", method, params };
    this.sendMessage(process, message);
  }

  private handleMessage(message: LspMessage, state: ServerState): void {
    // Response to one of our requests.
    if (message.id !== undefined && this.pendingRequests.has(message.id)) {
      const pending = this.pendingRequests.get(message.id);
      if (!pending) return;
      this.pendingRequests.delete(message.id);

      if (message.error) {
        pending.reject(new Error(message.error.message));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    // Server -> client request (must respond).
    if (message.id !== undefined && message.method) {
      const result = this.handleServerRequest(message.method, message.params, state);
      this.sendMessage(state.process, { jsonrpc: "2.0", id: message.id, result });
      return;
    }

    // Notifications.
    if (!message.method) return;

    if (message.method === "textDocument/publishDiagnostics") {
      const params = message.params as { uri: string; diagnostics: LspDiagnostic[] };
      if (params?.uri) {
        state.diagnostics.set(params.uri, params.diagnostics ?? []);
      }
      return;
    }

    if (message.method === "window/logMessage" || message.method === "window/showMessage") {
      try {
        process.stderr.write(`[enrilsp] ${message.method}: ${JSON.stringify(message.params)}\n`);
      } catch {
        process.stderr.write(`[enrilsp] ${message.method}\n`);
      }
    }
  }

  private handleServerRequest(method: string, params: unknown, state: ServerState): unknown {
    // Fix for csharp-ls on Windows: it uses workDone progress.
    if (method === "window/workDoneProgress/create") {
      return null;
    }

    if (method === "workspace/configuration") {
      const p = params as { items?: Array<unknown> };
      const count = Array.isArray(p?.items) ? p.items.length : 0;
      return Array.from({ length: count }, () => ({}));
    }

    if (method === "workspace/workspaceFolders") {
      const uri = pathToUri(state.workspaceRoot);
      return [{ uri, name: "workspace" }];
    }

    if (method === "client/registerCapability" || method === "client/unregisterCapability") {
      return null;
    }

    if (method === "workspace/applyEdit") {
      return { applied: false, failureReason: "EnriLSP does not apply edits via LSP requests" };
    }

    if (method === "window/showMessageRequest") {
      return null;
    }

    // Best-effort: avoid crashing servers that are strict about "Method not found".
    process.stderr.write(`[enrilsp] Unhandled server request: ${method}\n`);
    return null;
  }

  private async ensureFileOpen(state: ServerState, filePath: string): Promise<boolean> {
    const absolutePath = resolve(filePath);
    const uri = pathToUri(absolutePath);

    if (state.openFiles.has(uri)) return false;

    const text = await readFile(absolutePath, "utf8");
    const languageId = this.getLanguageId(absolutePath);

    state.openFiles.add(uri);
    state.fileVersions.set(uri, 1);

    this.sendNotification(state.process, "textDocument/didOpen", {
      textDocument: {
        uri,
        languageId,
        version: 1,
        text,
      },
    });

    return true;
  }

  async syncFileContent(filePath: string): Promise<void> {
    const serverState = await this.getServer(filePath);
    await serverState.initializationPromise;

    const absolutePath = resolve(filePath);
    const uri = pathToUri(absolutePath);

    if (!serverState.openFiles.has(uri)) {
      await this.ensureFileOpen(serverState, absolutePath);
      return;
    }

    const text = await readFile(absolutePath, "utf8");
    const currentVersion = serverState.fileVersions.get(uri) ?? 1;
    const nextVersion = currentVersion + 1;
    serverState.fileVersions.set(uri, nextVersion);

    this.sendNotification(serverState.process, "textDocument/didChange", {
      textDocument: { uri, version: nextVersion },
      contentChanges: [{ text }],
    });
  }

  private async getDocumentSymbols(filePath: string): Promise<Array<DocumentSymbol | SymbolInformation>> {
    const state = await this.getServer(filePath);
    await state.initializationPromise;

    const wasJustOpened = await this.ensureFileOpen(state, filePath);
    if (wasJustOpened) {
      // Small delay so the server can ingest didOpen before symbol queries.
      await new Promise((r) => setTimeout(r, 200));
    }

    const uri = pathToUri(resolve(filePath));
    const result = await this.sendRequest(
      state.process,
      "textDocument/documentSymbol",
      { textDocument: { uri } },
      30_000
    );

    if (!Array.isArray(result)) return [];
    return result as Array<DocumentSymbol | SymbolInformation>;
  }

  async findSymbolsByName(
    filePath: string,
    symbolName: string,
    symbolKind?: string
  ): Promise<{ matches: SymbolMatch[]; warning?: string }> {
    const docs = await this.getDocumentSymbols(filePath);
    const desiredKind = this.symbolKindFromString(symbolKind);

    const matches: SymbolMatch[] = [];

    const pushMatch = (name: string, kind: number, position: LspPosition) => {
      if (name !== symbolName) return;
      if (desiredKind !== undefined && kind !== desiredKind) return;
      matches.push({ name, kind, position });
    };

    const walkDocumentSymbol = (sym: DocumentSymbol) => {
      pushMatch(sym.name, sym.kind, sym.selectionRange.start);
      for (const child of sym.children ?? []) {
        walkDocumentSymbol(child);
      }
    };

    for (const sym of docs) {
      if (!sym) continue;
      if ("location" in sym) {
        const si = sym as SymbolInformation;
        pushMatch(si.name, si.kind, si.location.range.start);
        continue;
      }
      walkDocumentSymbol(sym as DocumentSymbol);
    }

    // Helpful warning for clients: documentSymbol only finds declarations within the file.
    const warning =
      matches.length === 0
        ? "Note: EnriLSP uses LSP document symbols, which only includes declarations in the given file. If you are trying to resolve a symbol usage, provide a cursor position instead."
        : undefined;

    return { matches, warning };
  }

  async findDefinition(filePath: string, position: LspPosition): Promise<LspLocation[]> {
    const state = await this.getServer(filePath);
    await state.initializationPromise;

    const wasJustOpened = await this.ensureFileOpen(state, filePath);
    if (wasJustOpened) {
      await new Promise((r) => setTimeout(r, 200));
    }

    const uri = pathToUri(resolve(filePath));
    const result = await this.sendRequest(
      state.process,
      "textDocument/definition",
      { textDocument: { uri }, position },
      30_000
    );

    return this.normalizeLocations(result);
  }

  async findReferences(
    filePath: string,
    position: LspPosition,
    includeDeclaration = true
  ): Promise<LspLocation[]> {
    const state = await this.getServer(filePath);
    await state.initializationPromise;

    const wasJustOpened = await this.ensureFileOpen(state, filePath);
    if (wasJustOpened) {
      await new Promise((r) => setTimeout(r, 200));
    }

    const uri = pathToUri(resolve(filePath));
    const result = await this.sendRequest(
      state.process,
      "textDocument/references",
      {
        textDocument: { uri },
        position,
        context: { includeDeclaration },
      },
      30_000
    );

    return this.normalizeLocations(result);
  }

  async renameSymbol(filePath: string, position: LspPosition, newName: string): Promise<LspWorkspaceEdit> {
    const state = await this.getServer(filePath);
    await state.initializationPromise;

    const wasJustOpened = await this.ensureFileOpen(state, filePath);
    if (wasJustOpened) {
      await new Promise((r) => setTimeout(r, 200));
    }

    const uri = pathToUri(resolve(filePath));
    const result = await this.sendRequest(
      state.process,
      "textDocument/rename",
      { textDocument: { uri }, position, newName },
      60_000
    );

    if (!result || typeof result !== "object") {
      return {};
    }
    return result as LspWorkspaceEdit;
  }

  async getDiagnostics(filePath: string): Promise<LspDiagnostic[]> {
    const state = await this.getServer(filePath);
    await state.initializationPromise;
    await this.ensureFileOpen(state, filePath);

    const uri = pathToUri(resolve(filePath));
    return state.diagnostics.get(uri) ?? [];
  }

  async restartServers(
    extensions?: string[]
  ): Promise<{ success: boolean; restarted: string[]; failed: string[]; message: string }> {
    const restarted: string[] = [];
    const failed: string[] = [];

    const wanted = extensions?.map((e) => e.toLowerCase());

    for (const [key, state] of this.servers.entries()) {
      const matches =
        !wanted ||
        state.config.extensions.some((ext) => wanted.includes(ext.toLowerCase()));

      if (!matches) continue;

      try {
        state.process.kill();
        restarted.push(state.config.command.join(" "));
      } catch (error) {
        failed.push(state.config.command.join(" "));
        process.stderr.write(`[enrilsp] Failed to kill server: ${error}\n`);
      } finally {
        this.servers.delete(key);
      }
    }

    const message = `Restarted ${restarted.length} server(s)${failed.length ? `, failed: ${failed.length}` : ""}.`;
    return { success: failed.length === 0, restarted, failed, message };
  }

  private normalizeLocations(result: unknown): LspLocation[] {
    if (!result) return [];

    if (Array.isArray(result)) {
      if (result.length === 0) return [];
      const first = result[0] as Record<string, unknown> | undefined;

      // Location[]
      if (first && "uri" in first && "range" in first) {
        return (result as LspLocation[]).map((loc) => ({ uri: loc.uri, range: loc.range }));
      }

      // LocationLink[]
      if (first && "targetUri" in first && "targetRange" in first) {
        return (result as LspLocationLink[]).map((link) => ({
          uri: link.targetUri,
          range: link.targetRange,
        }));
      }

      return [];
    }

    if (typeof result === "object") {
      const obj = result as Record<string, unknown>;

      // Location
      if ("uri" in obj && "range" in obj) {
        return [result as LspLocation];
      }

      // LocationLink
      if ("targetUri" in obj && "targetRange" in obj) {
        const link = result as LspLocationLink;
        return [{ uri: link.targetUri, range: link.targetRange }];
      }
    }

    return [];
  }

  formatLocations(locations: LspLocation[]): string[] {
    return locations.map((loc) => {
      const filePath = uriToPath(loc.uri);
      const { start } = loc.range;
      return `${filePath}:${start.line + 1}:${start.character + 1}`;
    });
  }
}
