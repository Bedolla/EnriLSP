export type LspId = number | string;

export interface EnriLspServerConfig {
  /**
   * Human-friendly name (optional, for logs).
   */
  name?: string;
  /**
   * File extensions (without dot), e.g. ["cs", "csx"].
   */
  extensions: string[];
  /**
   * Command and args to start the LSP server, e.g. ["csharp-ls", "--stdio"].
   */
  command: string[];
  /**
   * Workspace root directory for the server (defaults to process.cwd()).
   */
  rootDir?: string;
  /**
   * Optional LSP initializationOptions forwarded to `initialize`.
   */
  initializationOptions?: unknown;
  /**
   * Optional warmup delay after `initialized` (some servers need time on Windows).
   */
  warmupMs?: number;
}

export interface EnriLspConfig {
  servers: EnriLspServerConfig[];
}

export interface LspPosition {
  line: number;
  character: number;
}

export interface LspRange {
  start: LspPosition;
  end: LspPosition;
}

export interface LspLocation {
  uri: string;
  range: LspRange;
}

export interface LspLocationLink {
  targetUri: string;
  targetRange: LspRange;
  targetSelectionRange?: LspRange;
  originSelectionRange?: LspRange;
}

export interface LspDiagnostic {
  range: LspRange;
  severity?: number;
  code?: string | number;
  source?: string;
  message: string;
}

export interface LspTextEdit {
  range: LspRange;
  newText: string;
}

export interface LspWorkspaceEdit {
  changes?: Record<string, LspTextEdit[]>;
}

export interface LspError {
  code: number;
  message: string;
  data?: unknown;
}

export interface LspMessage {
  jsonrpc: "2.0";
  id?: LspId;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: LspError;
}

export interface SymbolMatch {
  name: string;
  kind: number;
  position: LspPosition;
}
