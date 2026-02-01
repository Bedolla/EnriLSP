import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";

type PruneTarget = {
  id: string;
  label: string;
  paths: string[];
  description: string;
};

type ParsedArgs = {
  help: boolean;
  list: boolean;
  dryRun: boolean;
  yes: boolean;
  all: boolean;
  targets: string[];
};

export class PruneCommand {
  private isTruthy(value: string): boolean {
    const v = value.trim().toLowerCase();
    return v === "y" || v === "yes" || v === "s" || v === "si";
  }

  private getWindowsLocalAppData(): string {
    return process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
  }

  private getTargets(): PruneTarget[] {
    if (process.platform !== "win32") return [];

    const local = this.getWindowsLocalAppData();
    return [
      {
        id: "enrilsp",
        label: "EnriLSP cache",
        paths: [join(local, "EnriLSP")],
        description:
          "Downloaded binaries and caches used by EnriLSP installers (marksman/texlab/zls/terraform-ls/postgres-ls/cmake-language-server venv, etc.)",
      },
      {
        id: "powershell-editor-services",
        label: "PowerShellEditorServices",
        paths: [join(local, "EnriLSP", "PowerShellEditorServices"), join(local, "PowerShellEditorServices")],
        description:
          "Installed by the PowerShell preset installer (also removes older installs at %LOCALAPPDATA%\\PowerShellEditorServices)",
      },
      {
        id: "jdtls",
        label: "JDTLS (Java)",
        paths: [join(local, "EnriLSP", "jdtls"), join(local, "jdtls")],
        description: "Installed by the Java preset installer (also removes older installs at %LOCALAPPDATA%\\jdtls)",
      },
      {
        id: "kotlin-lsp",
        label: "Kotlin LSP",
        paths: [join(local, "EnriLSP", "kotlin-lsp"), join(local, "kotlin-lsp")],
        description: "Installed by the Kotlin preset installer (also removes older installs at %LOCALAPPDATA%\\kotlin-lsp)",
      },
      {
        id: "lua-language-server",
        label: "Lua Language Server",
        paths: [join(local, "EnriLSP", "lua-language-server"), join(local, "lua-language-server")],
        description:
          "Installed by the Lua preset installer (also removes older installs at %LOCALAPPDATA%\\lua-language-server)",
      },
    ];
  }

  private printHelp(): void {
    console.log("EnriLSP prune");
    console.log("");
    console.log("Removes LocalAppData folders created by EnriLSP installers.");
    console.log("It does NOT touch your config at ~/.Enri/EnriLSP/Config.json.");
    console.log("");
    console.log("Usage:");
    console.log("  enrilsp prune                (interactive, asks before deleting)");
    console.log("  enrilsp prune --list         (show targets)");
    console.log("  enrilsp prune --dry-run      (show what would be deleted)");
    console.log("  enrilsp prune --yes --all    (delete all targets)");
    console.log("  enrilsp prune --yes --target enrilsp");
    console.log("");
    console.log("Notes:");
    console.log("- Node global packages under %APPDATA%\\npm are NOT removed by prune.");
    console.log("- Close any running LSPs first, otherwise Windows may fail to delete locked files.");
  }

  private parseArgs(argv: string[]): ParsedArgs {
    const out: ParsedArgs = {
      help: false,
      list: false,
      dryRun: false,
      yes: false,
      all: false,
      targets: [],
    };

    for (let i = 0; i < argv.length; i++) {
      const a = argv[i]!;
      if (a === "--help" || a === "-h") out.help = true;
      else if (a === "--list") out.list = true;
      else if (a === "--dry-run") out.dryRun = true;
      else if (a === "--yes" || a === "-y") out.yes = true;
      else if (a === "--all") out.all = true;
      else if (a === "--target") {
        const v = argv[i + 1];
        if (v) {
          out.targets.push(v);
          i++;
        }
      }
    }

    if (out.yes && out.dryRun) {
      throw new Error("Cannot combine --yes with --dry-run.");
    }
    return out;
  }

  private formatTargetLine(t: PruneTarget): string {
    const pathLines = t.paths.map((p) => `  ${p} ${existsSync(p) ? "(exists)" : "(missing)"}`);
    return `${t.id}:\n${pathLines.join("\n")}\n  ${t.description}`;
  }

  private async deleteTarget(path: string): Promise<void> {
    const resolvedPath = resolve(path);
    await rm(resolvedPath, { recursive: true, force: true, maxRetries: 2, retryDelay: 200 });
  }

  private async promptSelectTargets(
    rl: ReturnType<typeof createInterface>,
    targets: PruneTarget[]
  ): Promise<PruneTarget[]> {
    console.log("");
    console.log("Select what to prune (comma-separated numbers):");
    targets.forEach((t, i) => {
      const exists = t.paths.some((p) => existsSync(p));
      console.log(`  ${i + 1}) ${t.label} (${t.id}) ${exists ? "" : "[missing]"}`);
      t.paths.forEach((p) => console.log(`     ${p}`));
    });
    console.log("  a) All of the above");

    const raw = (await rl.question("> ")).trim().toLowerCase();
    if (raw === "a" || raw === "all") return targets;
    if (!raw) return [];

    const parts = raw
      .split(/[,\s]+/g)
      .map((p) => p.trim())
      .filter((p) => p.length > 0);

    const indexes = new Set<number>();
    for (const part of parts) {
      const n = Number.parseInt(part, 10);
      if (!Number.isFinite(n) || n < 1 || n > targets.length) {
        throw new Error(`Invalid selection: "${part}"`);
      }
      indexes.add(n - 1);
    }

    return Array.from(indexes)
      .sort((a, b) => a - b)
      .map((idx) => targets[idx]!)
      .filter(Boolean);
  }

  public async run(argvFull: string[]): Promise<void> {
    const argv = argvFull[0] === "prune" ? argvFull.slice(1) : argvFull;
    const args = this.parseArgs(argv);

    if (args.help) {
      this.printHelp();
      return;
    }

    const targets = this.getTargets();
    if (targets.length === 0) {
      console.error("[EnriLSP] Prune is currently only implemented for Windows.");
      process.exitCode = 1;
      return;
    }

    if (args.list) {
      console.log(targets.map((t) => this.formatTargetLine(t)).join("\n\n"));
      return;
    }

    const targetIds = new Set(targets.map((t) => t.id));
    const requestedIds = args.all ? targets.map((t) => t.id) : args.targets;

    // Non-interactive path: require explicit --all or --target.
    const canPrompt = process.stdin.isTTY && process.stdout.isTTY;
    if (!canPrompt && requestedIds.length === 0) {
      console.error("[EnriLSP] No targets selected. Use --list, --all, or --target <id>.");
      process.exitCode = 1;
      return;
    }

    if (!canPrompt && !args.dryRun && !args.yes) {
      console.error("[EnriLSP] Refusing to delete without a TTY. Re-run with --yes.");
      process.exitCode = 1;
      return;
    }

    let selected: PruneTarget[] = [];
    if (requestedIds.length > 0) {
      const unknown = requestedIds.filter((id) => !targetIds.has(id));
      if (unknown.length > 0) {
        throw new Error(`Unknown target(s): ${unknown.join(", ")}. Use --list to see valid ids.`);
      }
      selected = targets.filter((t) => requestedIds.includes(t.id));
    } else {
      const rl = createInterface({ input: process.stdin, output: process.stdout });
      try {
        selected = await this.promptSelectTargets(rl, targets);
        if (selected.length === 0) {
          console.log("Nothing selected.");
          return;
        }

        console.log("");
        console.log("Selected:");
        selected.forEach((t) => t.paths.forEach((p) => console.log(`- ${t.id}: ${p}`)));

        if (!args.yes) {
          const confirm = await rl.question(args.dryRun ? "Proceed with dry-run? [y/N]: " : "DELETE these folders? [y/N]: ");
          if (!this.isTruthy(confirm)) {
            console.log("Canceled.");
            return;
          }
        }
      } finally {
        rl.close();
      }
    }

    console.log("");
    console.log(args.dryRun ? "[EnriLSP] Dry-run. Nothing will be deleted." : "[EnriLSP] Pruning...");

    for (const t of selected) {
      for (const path of t.paths) {
        const exists = existsSync(path);
        if (!exists) {
          console.log(`[EnriLSP] Skip (missing): ${path}`);
          continue;
        }

        if (args.dryRun) {
          console.log(`[EnriLSP] Would delete: ${path}`);
          continue;
        }

        try {
          await this.deleteTarget(path);
          console.log(`[EnriLSP] Deleted: ${path}`);
        } catch (error) {
          console.error(`[EnriLSP] Failed to delete ${path}: ${error instanceof Error ? error.message : String(error)}`);
          process.exitCode = 1;
        }
      }
    }

    console.log("");
    console.log("[EnriLSP] Done.");
  }
}
