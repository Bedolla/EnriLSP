import { spawn, type ChildProcess } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { basename, dirname, extname, isAbsolute, join, normalize, relative, resolve } from "node:path";

import { packageInfoService } from "../package-info.js";
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
import { uriConverter } from "./utils.js";

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
  capabilities: Record<string, unknown>;
  openFiles: Set<string>;
  fileVersions: Map<string, number>;
  diagnostics: Map<string, LspDiagnostic[]>;
  buffer: Buffer;
  workspaceRoot: string;
}

export class LspClient {
  private readonly config: EnriLspConfig;

  private readonly servers: Map<string, ServerState> = new Map<string, ServerState>();
  private readonly serversStarting: Map<string, Promise<ServerState>> = new Map<string, Promise<ServerState>>();

  private readonly require: NodeRequire = createRequire(import.meta.url);

  private nextId: number = 1;
  private readonly pendingRequests: Map<LspId, PendingRequest> = new Map<LspId, PendingRequest>();

  private readonly workspaceRootCache: Map<string, string> = new Map<string, string>();
  private readonly typescriptTsdkCache: Map<string, string | null> = new Map<string, string | null>();

  public constructor(config: EnriLspConfig) {
    this.config = config;
  }

  public symbolKindToString(kind: number): string {
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

  public symbolKindFromString(kind?: string): number | undefined {
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

  private getMatchingServerConfigsForFile(filePath: string): EnriLspServerConfig[] {
    const ext = extname(filePath).toLowerCase().replace(/^\./, "");

    // For extensionless files (e.g. "Dockerfile" or ".gitignore"), fall back to filename matching.
    // This keeps config simple while supporting common non-extension conventions.
    const fileName = basename(filePath).toLowerCase();
    const fileNameNoDot = fileName.startsWith(".") ? fileName.slice(1) : "";

    // Add common filename "aliases" so users can configure one canonical token and still match variants:
    // - Dockerfile.dev, Dockerfile.prod, etc -> "dockerfile"
    // - .gitignore.local -> "gitignore"
    const fileAliases = this.getFileAliases(fileName);

    // Support "compound extensions" like:
    // - `Button.module.css` -> `module.css`
    // - `types.d.ts` -> `d.ts`
    // This is crucial for cases where two servers overlap on the final extension (e.g. css + cssmodules).
    const nameParts = fileName.split(".");
    const compoundExt = nameParts.length >= 3 ? nameParts.slice(-2).join(".") : "";

    const matchKeys = [ext, compoundExt, fileName, fileNameNoDot, ...fileAliases].filter(
      (v): v is string => !!v && v.trim().length > 0
    );
    if (matchKeys.length === 0) return [];

    const wanted = new Set(matchKeys.map((k) => k.toLowerCase()));
    return this.config.servers.filter((server) => {
      for (const e of server.extensions) {
        if (wanted.has(e.toLowerCase())) return true;
      }
      return false;
    });
  }

  private getFileAliases(fileNameLowercase: string): string[] {
    const aliases: string[] = [];

    // Dockerfile variants (very common)
    if (fileNameLowercase === "dockerfile" || fileNameLowercase.startsWith("dockerfile.")) {
      aliases.push("dockerfile");
    }

    // Dotfile variants: ".gitignore.local" should still match config token "gitignore"
    if (fileNameLowercase === ".gitignore" || fileNameLowercase.startsWith(".gitignore.")) {
      aliases.push("gitignore");
    }

    return aliases;
  }

  private isPlainObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  private shouldConsiderTypescriptTsdk(serverConfig: EnriLspServerConfig): boolean {
    const name = (serverConfig.name ?? "").toLowerCase();
    if (name.includes("vtsls") || name.includes("typescript") || name.includes("astro") || name.includes("vue") || name.includes("svelte")) {
      return true;
    }

    const exts = serverConfig.extensions.map((e) => e.toLowerCase());
    const tsLike = new Set<string>(["ts", "tsx", "js", "jsx", "astro", "vue", "svelte"]);
    return exts.some((e) => tsLike.has(e));
  }

  private getWindowsRoamingAppData(): string | null {
    if (process.platform !== "win32") return null;
    return process.env.APPDATA ?? null;
  }

  private resolveTypescriptTsdkDirectory(workspaceRoot: string): string | null {
    const cacheKey = normalize(workspaceRoot);
    if (this.typescriptTsdkCache.has(cacheKey)) {
      return this.typescriptTsdkCache.get(cacheKey) ?? null;
    }

    const searchPaths: string[] = [cacheKey];
    const appData = this.getWindowsRoamingAppData();
    if (appData) {
      // Global npm installs typically land in: %APPDATA%\npm\node_modules\...
      searchPaths.push(join(appData, "npm", "node_modules"));
    }

    let resolvedTsdk: string | null = null;
    for (const base of searchPaths) {
      try {
        const tsserverLib = this.require.resolve("typescript/lib/tsserverlibrary.js", { paths: [base] });
        resolvedTsdk = dirname(tsserverLib);
        break;
      } catch {
        // Keep trying.
      }
    }

    this.typescriptTsdkCache.set(cacheKey, resolvedTsdk);
    return resolvedTsdk;
  }

  private applyAutoInitializationOptions(initializeParams: Record<string, unknown>, state: ServerState): void {
    if (!this.shouldConsiderTypescriptTsdk(state.config)) {
      return;
    }

    const tsdkDir = this.resolveTypescriptTsdkDirectory(state.workspaceRoot);
    if (!tsdkDir) {
      return;
    }

    const existing = initializeParams.initializationOptions;
    if (existing !== undefined && !this.isPlainObject(existing)) {
      // If the user provided a non-object initializationOptions, do not attempt to merge.
      return;
    }

    const initOptions: Record<string, unknown> = this.isPlainObject(existing) ? { ...existing } : {};
    const existingTypescript = initOptions.typescript;
    const typescriptOptions: Record<string, unknown> = this.isPlainObject(existingTypescript) ? { ...existingTypescript } : {};

    const currentTsdk = typescriptOptions.tsdk;
    if (typeof currentTsdk !== "string" || currentTsdk.trim().length === 0) {
      typescriptOptions.tsdk = tsdkDir;
    }

    initOptions.typescript = typescriptOptions;
    initializeParams.initializationOptions = initOptions;
  }

  private orderServerConfigsBySpecificity(
    filePath: string,
    servers: EnriLspServerConfig[]
  ): EnriLspServerConfig[] {
    if (servers.length <= 1) return servers;

    const absoluteFilePath = normalize(
      isAbsolute(filePath) ? filePath : resolve(process.cwd(), filePath)
    );

    const scored = servers.map((server, index) => {
      if (!server.rootDir) {
        // Global server: matches anything, but less specific than a rootDir that actually contains the file.
        return { server, index, score: 0 };
      }

      const root = normalize(
        isAbsolute(server.rootDir)
          ? server.rootDir
          : resolve(process.cwd(), server.rootDir)
      );

      const rel = relative(root, absoluteFilePath);
      const isInside = rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
      return { server, index, score: isInside ? 10_000 + root.length : -1 };
    });

    scored.sort((a, b) => b.score - a.score || a.index - b.index);
    return scored.map((s) => s.server);
  }

  private getServerForFile(filePath: string): EnriLspServerConfig | null {
    const matching = this.getMatchingServerConfigsForFile(filePath);
    if (matching.length === 0) return null;
    if (matching.length === 1) return matching[0] ?? null;
    const ordered = this.orderServerConfigsBySpecificity(filePath, matching);
    return ordered[0] ?? matching[0] ?? null;
  }

  private makeServerKey(server: EnriLspServerConfig, workspaceRoot: string): string {
    const root = normalize(workspaceRoot);
    return JSON.stringify({
      command: server.command,
      rootDir: root,
      extensions: server.extensions,
    });
  }

  private async getServerForConfig(filePath: string, serverConfig: EnriLspServerConfig): Promise<ServerState> {
    const workspaceRoot = await this.getWorkspaceRootForFile(filePath, serverConfig);
    const key = this.makeServerKey(serverConfig, workspaceRoot);
    const existing = this.servers.get(key);
    if (existing) return existing;

    const starting = this.serversStarting.get(key);
    if (starting) return starting;

    const startPromise = this.startServer(serverConfig, workspaceRoot);
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

  private async getServer(filePath: string): Promise<ServerState> {
    const serverConfig = this.getServerForFile(filePath);
    if (!serverConfig) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }
    return await this.getServerForConfig(filePath, serverConfig);
  }

  private async startServer(
    serverConfig: EnriLspServerConfig,
    workspaceRoot: string
  ): Promise<ServerState> {
    const command = serverConfig.command[0];
    if (!command) {
      throw new Error("Invalid server config: command[0] is required");
    }

    const args = serverConfig.command.slice(1);
    workspaceRoot = normalize(workspaceRoot);

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
      capabilities: {},
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
        `[EnriLSP] LSP server exited: ${serverConfig.command.join(" ")} (code=${code}, signal=${signal})\n`
      );

      // Drop from caches so a future request can restart it.
      const key = this.makeServerKey(serverConfig, workspaceRoot);
      this.servers.delete(key);
      this.serversStarting.delete(key);
    });

    await this.initializeServer(state);
    return state;
  }

  private workspaceRootCacheKey(languageId: string, directory: string): string {
    // Cache is scoped by language family because preferred markers differ (e.g. C# uses .sln/.csproj).
    return `${languageId.toLowerCase()}|${normalize(directory)}`;
  }

  private async tryReadDirNamesLowercase(dir: string): Promise<string[] | null> {
    try {
      const entries = await readdir(dir, { withFileTypes: true });
      return entries.map((e) => e.name.toLowerCase());
    } catch {
      return null;
    }
  }

  private async detectWorkspaceRootFromDir(startDir: string, languageId: string): Promise<string> {
    const start = normalize(startDir);
    const cacheKey = this.workspaceRootCacheKey(languageId, start);
    const cached = this.workspaceRootCache.get(cacheKey);
    if (cached) return cached;

    const visited: string[] = [];

    let current = start;
    while (true) {
      visited.push(current);

      const names = await this.tryReadDirNamesLowercase(current);
      if (names) {
        const has = (fileName: string) => names.includes(fileName.toLowerCase());
        const hasAnySuffix = (suffix: string) =>
          names.some((n) => n.toLowerCase().endsWith(suffix.toLowerCase()));

        const lang = languageId.toLowerCase();

        // Language-specific root markers (highest priority).
        if (lang === "csharp") {
          if (hasAnySuffix(".sln") || hasAnySuffix(".csproj") || hasAnySuffix(".fsproj")) {
            for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
            return current;
          }
        }

        if (
          lang === "typescript" ||
          lang === "typescriptreact" ||
          lang === "javascript" ||
          lang === "javascriptreact" ||
          lang === "html" ||
          lang === "css" ||
          lang === "scss" ||
          lang === "less" ||
          lang === "json" ||
          lang === "jsonc"
        ) {
          if (has("package.json") || has("tsconfig.json")) {
            for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
            return current;
          }
        }

        if (lang === "python") {
          if (has("pyproject.toml") || has("setup.py") || has("requirements.txt") || has("pipfile")) {
            for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
            return current;
          }
        }

        if (lang === "rust") {
          if (has("cargo.toml")) {
            for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
            return current;
          }
        }

        if (lang === "go") {
          if (has("go.mod")) {
            for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
            return current;
          }
        }

        if (lang === "java" || lang === "kotlin") {
          if (has("pom.xml") || has("build.gradle") || has("settings.gradle") || has("gradlew")) {
            for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
            return current;
          }
        }

        // Generic marker (lowest priority, still better than a random cwd).
        if (has(".git")) {
          for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), current);
          return current;
        }
      }

      const parent = dirname(current);
      if (parent === current) break;
      current = parent;
    }

    // Fallback: use the starting directory (file's folder).
    for (const d of visited) this.workspaceRootCache.set(this.workspaceRootCacheKey(languageId, d), start);
    return start;
  }

  private async getWorkspaceRootForFile(
    filePath: string,
    serverConfig: EnriLspServerConfig
  ): Promise<string> {
    if (serverConfig.rootDir) {
      return normalize(
        isAbsolute(serverConfig.rootDir)
          ? serverConfig.rootDir
          : resolve(process.cwd(), serverConfig.rootDir)
      );
    }

    const languageId = this.getLanguageId(filePath);
    const startDir = dirname(filePath);
    return await this.detectWorkspaceRootFromDir(startDir, languageId);
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
        process.stderr.write(`[EnriLSP] Failed to parse LSP message: ${error}\n`);
      }
    }
  }

  private async initializeServer(state: ServerState): Promise<void> {
    const rootUri = uriConverter.pathToUri(state.workspaceRoot);

    const initializeParams: Record<string, unknown> = {
      processId: state.process.pid ?? null,
      clientInfo: { name: "EnriLSP", version: packageInfoService.getVersion() },
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

    this.applyAutoInitializationOptions(initializeParams, state);

    const initResult = await this.sendRequest(
      state.process,
      "initialize",
      initializeParams,
      30_000
    );
    if (initResult && typeof initResult === "object") {
      const caps = (initResult as { capabilities?: unknown }).capabilities;
      if (caps && typeof caps === "object") {
        state.capabilities = caps as Record<string, unknown>;
      }
    }
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
        process.stderr.write(`[EnriLSP] ${message.method}: ${JSON.stringify(message.params)}\n`);
      } catch {
        process.stderr.write(`[EnriLSP] ${message.method}\n`);
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
      const uri = uriConverter.pathToUri(state.workspaceRoot);
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
    process.stderr.write(`[EnriLSP] Unhandled server request: ${method}\n`);
    return null;
  }

  private async ensureFileOpen(state: ServerState, filePath: string): Promise<boolean> {
    const absolutePath = resolve(filePath);
    const uri = uriConverter.pathToUri(absolutePath);

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

  private serverAdvertisedCapability(state: ServerState, key: string): boolean {
    const caps = state.capabilities;
    const hasCaps = caps && typeof caps === "object" && Object.keys(caps).length > 0;
    if (!hasCaps) return true; // unknown => optimistic

    const raw = (caps as Record<string, unknown>)[key];
    if (raw === undefined || raw === null) return false;
    if (typeof raw === "boolean") return raw;
    return true; // objects, numbers, etc.
  }

  private getOrderedServerConfigsForFile(filePath: string): EnriLspServerConfig[] {
    const matching = this.getMatchingServerConfigsForFile(filePath);
    return this.orderServerConfigsBySpecificity(filePath, matching);
  }

  private async getServerStatesForFile(filePath: string): Promise<ServerState[]> {
    const ordered = this.getOrderedServerConfigsForFile(filePath);
    if (ordered.length === 0) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }

    const states: ServerState[] = [];
    const errors: string[] = [];
    for (const cfg of ordered) {
      try {
        const state = await this.getServerForConfig(filePath, cfg);
        await state.initializationPromise;
        states.push(state);
      } catch (error) {
        const label = cfg.name ?? cfg.command[0] ?? "(unnamed)";
        errors.push(`${label}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }

    if (states.length === 0) {
      throw new Error(
        `No configured LSP server could be started for ${filePath}.\n` +
          (errors.length ? `Errors:\n${errors.join("\n")}` : "")
      );
    }
    return states;
  }

  public async syncFileContent(filePath: string): Promise<void> {
    const absolutePath = resolve(filePath);
    const uri = uriConverter.pathToUri(absolutePath);
    const text = await readFile(absolutePath, "utf8");

    // Broadcast updates to all matching servers, so diagnostics from secondary servers (e.g. ESLint) stay fresh.
    const states = await this.getServerStatesForFile(absolutePath);
    for (const state of states) {
      if (!state.openFiles.has(uri)) {
        await this.ensureFileOpen(state, absolutePath);
        continue;
      }

      const currentVersion = state.fileVersions.get(uri) ?? 1;
      const nextVersion = currentVersion + 1;
      state.fileVersions.set(uri, nextVersion);

      this.sendNotification(state.process, "textDocument/didChange", {
        textDocument: { uri, version: nextVersion },
        contentChanges: [{ text }],
      });
    }
  }

  private async getDocumentSymbols(filePath: string): Promise<Array<DocumentSymbol | SymbolInformation>> {
    const configs = this.getOrderedServerConfigsForFile(filePath);
    if (configs.length === 0) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }
    const uri = uriConverter.pathToUri(resolve(filePath));

    for (const cfg of configs) {
      let state: ServerState;
      try {
        state = await this.getServerForConfig(filePath, cfg);
        await state.initializationPromise;
      } catch {
        continue;
      }
      if (!this.serverAdvertisedCapability(state, "documentSymbolProvider")) continue;

      const wasJustOpened = await this.ensureFileOpen(state, filePath);
      if (wasJustOpened) {
        // Small delay so the server can ingest didOpen before symbol queries.
        await new Promise((r) => setTimeout(r, 200));
      }

      try {
        const result = await this.sendRequest(
          state.process,
          "textDocument/documentSymbol",
          { textDocument: { uri } },
          30_000
        );

        if (!Array.isArray(result)) continue;
        return result as Array<DocumentSymbol | SymbolInformation>;
      } catch {
        // Try the next server.
      }
    }

    return [];
  }

  public async findSymbolsByName(
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

  public async findDefinition(filePath: string, position: LspPosition): Promise<LspLocation[]> {
    const configs = this.getOrderedServerConfigsForFile(filePath);
    if (configs.length === 0) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }
    const uri = uriConverter.pathToUri(resolve(filePath));

    for (const cfg of configs) {
      let state: ServerState;
      try {
        state = await this.getServerForConfig(filePath, cfg);
        await state.initializationPromise;
      } catch {
        continue;
      }
      if (!this.serverAdvertisedCapability(state, "definitionProvider")) continue;

      const wasJustOpened = await this.ensureFileOpen(state, filePath);
      if (wasJustOpened) {
        await new Promise((r) => setTimeout(r, 200));
      }

      try {
        const result = await this.sendRequest(
          state.process,
          "textDocument/definition",
          { textDocument: { uri }, position },
          30_000
        );
        return this.normalizeLocations(result);
      } catch {
        // Try the next server.
      }
    }

    // Fall back to the default selection (legacy behavior).
    const fallback = await this.getServer(filePath);
    const wasJustOpened = await this.ensureFileOpen(fallback, filePath);
    if (wasJustOpened) {
      await new Promise((r) => setTimeout(r, 200));
    }
    const result = await this.sendRequest(
      fallback.process,
      "textDocument/definition",
      { textDocument: { uri }, position },
      30_000
    );
    return this.normalizeLocations(result);
  }

  public async findReferences(
    filePath: string,
    position: LspPosition,
    includeDeclaration = true
  ): Promise<LspLocation[]> {
    const configs = this.getOrderedServerConfigsForFile(filePath);
    if (configs.length === 0) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }
    const uri = uriConverter.pathToUri(resolve(filePath));

    for (const cfg of configs) {
      let state: ServerState;
      try {
        state = await this.getServerForConfig(filePath, cfg);
        await state.initializationPromise;
      } catch {
        continue;
      }
      if (!this.serverAdvertisedCapability(state, "referencesProvider")) continue;

      const wasJustOpened = await this.ensureFileOpen(state, filePath);
      if (wasJustOpened) {
        await new Promise((r) => setTimeout(r, 200));
      }

      try {
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
      } catch {
        // Try the next server.
      }
    }

    const fallback = await this.getServer(filePath);
    const wasJustOpened = await this.ensureFileOpen(fallback, filePath);
    if (wasJustOpened) {
      await new Promise((r) => setTimeout(r, 200));
    }
    const result = await this.sendRequest(
      fallback.process,
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

  public async renameSymbol(filePath: string, position: LspPosition, newName: string): Promise<LspWorkspaceEdit> {
    const configs = this.getOrderedServerConfigsForFile(filePath);
    if (configs.length === 0) {
      throw new Error(`No LSP server configured for file: ${filePath}`);
    }
    const uri = uriConverter.pathToUri(resolve(filePath));

    for (const cfg of configs) {
      let state: ServerState;
      try {
        state = await this.getServerForConfig(filePath, cfg);
        await state.initializationPromise;
      } catch {
        continue;
      }
      if (!this.serverAdvertisedCapability(state, "renameProvider")) continue;

      const wasJustOpened = await this.ensureFileOpen(state, filePath);
      if (wasJustOpened) {
        await new Promise((r) => setTimeout(r, 200));
      }

      try {
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
      } catch {
        // Try the next server.
      }
    }

    const fallback = await this.getServer(filePath);
    const wasJustOpened = await this.ensureFileOpen(fallback, filePath);
    if (wasJustOpened) {
      await new Promise((r) => setTimeout(r, 200));
    }
    const result = await this.sendRequest(
      fallback.process,
      "textDocument/rename",
      { textDocument: { uri }, position, newName },
      60_000
    );
    if (!result || typeof result !== "object") {
      return {};
    }
    return result as LspWorkspaceEdit;
  }

  public async getDiagnostics(filePath: string): Promise<LspDiagnostic[]> {
    const states = await this.getServerStatesForFile(filePath);
    const uri = uriConverter.pathToUri(resolve(filePath));

    let opened = false;
    for (const state of states) {
      const wasOpened = await this.ensureFileOpen(state, filePath);
      opened = opened || wasOpened;
    }

    if (opened) {
      // Give servers a moment to publish diagnostics (especially ESLint on Windows).
      await new Promise((r) => setTimeout(r, 300));
    }

    const merged: LspDiagnostic[] = [];
    for (const state of states) {
      const diags = state.diagnostics.get(uri) ?? [];
      const serverLabel = state.config.name ?? state.config.command[0] ?? "lsp";
      for (const d of diags) {
        merged.push({
          ...d,
          source: d.source ? d.source : serverLabel,
        });
      }
    }

    return merged;
  }

  public async restartServers(
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
        process.stderr.write(`[EnriLSP] Failed to kill server: ${error}\n`);
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

  public formatLocations(locations: LspLocation[]): string[] {
    return locations.map((loc) => {
      const filePath = uriConverter.uriToPath(loc.uri);
      const { start } = loc.range;
      return `${filePath}:${start.line + 1}:${start.character + 1}`;
    });
  }
}
