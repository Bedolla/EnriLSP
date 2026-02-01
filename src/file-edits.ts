import { copyFileSync, existsSync } from "node:fs";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

import type { LspTextEdit, LspWorkspaceEdit } from "./types.js";
import { uriConverter } from "./lsp/utils.js";

export interface ApplyWorkspaceEditResult {
  success: boolean;
  filesModified: string[];
  backupFiles: string[];
  error?: string;
}

export class WorkspaceEditApplier {
  private computeLineOffsets(text: string): number[] {
    const offsets: number[] = [0];
    for (let i = 0; i < text.length; i++) {
      if (text[i] === "\n") offsets.push(i + 1);
    }
    return offsets;
  }

  private offsetAt(lineOffsets: number[], position: { line: number; character: number }, text: string): number {
    const line = Math.max(0, position.line);
    const character = Math.max(0, position.character);

    if (line >= lineOffsets.length) return text.length;
    return Math.min(text.length, lineOffsets[line] + character);
  }

  private applyTextEditsToContent(content: string, edits: LspTextEdit[]): string {
    if (edits.length === 0) return content;

    const lineOffsets = this.computeLineOffsets(content);
    const normalized = edits
      .map((edit) => {
        const start = this.offsetAt(lineOffsets, edit.range.start, content);
        const end = this.offsetAt(lineOffsets, edit.range.end, content);
        return { start, end, newText: edit.newText };
      })
      .sort((a, b) => b.start - a.start || b.end - a.end);

    let out = content;
    for (const edit of normalized) {
      if (edit.start > edit.end) {
        throw new Error(`Invalid edit: start(${edit.start}) > end(${edit.end})`);
      }
      out = out.slice(0, edit.start) + edit.newText + out.slice(edit.end);
    }
    return out;
  }

  public async applyWorkspaceEditToDisk(
    edit: LspWorkspaceEdit,
    options: { createBackups?: boolean; backupSuffix?: string } = {}
  ): Promise<ApplyWorkspaceEditResult> {
    const { createBackups = true, backupSuffix = ".bak" } = options;

    const filesModified: string[] = [];
    const backupFiles: string[] = [];

    if (!edit.changes || Object.keys(edit.changes).length === 0) {
      return { success: true, filesModified, backupFiles };
    }

    try {
      for (const [uri, edits] of Object.entries(edit.changes)) {
        const filePath = resolve(uriConverter.uriToPath(uri));
        const dir = dirname(filePath);
        await mkdir(dir, { recursive: true });

        if (!existsSync(filePath)) {
          throw new Error(`File does not exist: ${filePath}`);
        }

        if (createBackups) {
          const backupPath = filePath + backupSuffix;
          copyFileSync(filePath, backupPath);
          backupFiles.push(backupPath);
        }

        const original = await readFile(filePath, "utf8");
        const updated = this.applyTextEditsToContent(original, edits ?? []);

        const tmpPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;
        await writeFile(tmpPath, updated, "utf8");
        await rename(tmpPath, filePath);

        filesModified.push(filePath);
      }

      return { success: true, filesModified, backupFiles };
    } catch (error) {
      return { success: false, filesModified, backupFiles, error: String(error) };
    }
  }
}

export const workspaceEditApplier: WorkspaceEditApplier = new WorkspaceEditApplier();
