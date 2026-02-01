import { spawn } from "node:child_process";
import { copyFileSync, existsSync, readdirSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";

import type { EnriLspConfig, EnriLspServerConfig } from "./types.js";
import { configService } from "./config.js";
import { presetRegistry, type Preset } from "./presets.js";

export class MenuCommand {
  private isTruthy(value: string): boolean {
    const v = value.trim().toLowerCase();
    return v.startsWith("y") || v.startsWith("s");
  }

  private async readJsonConfigOrEmpty(path: string): Promise<EnriLspConfig> {
    if (!existsSync(path)) return { servers: [] };
    const raw = await readFile(path, "utf8");
    const parsed = JSON.parse(raw) as Partial<EnriLspConfig>;
    if (!parsed || !Array.isArray(parsed.servers)) return { servers: [] };
    return { servers: parsed.servers as EnriLspServerConfig[] };
  }

  private async ensureDirForFile(path: string): Promise<void> {
    await mkdir(dirname(path), { recursive: true });
  }

  private backupExistingFile(path: string): string | null {
    if (!existsSync(path)) return null;
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const backupPath = `${path}.bak-${stamp}`;
    copyFileSync(path, backupPath);
    return backupPath;
  }

  private async writeJsonConfig(path: string, config: EnriLspConfig): Promise<void> {
    await this.ensureDirForFile(path);
    await writeFile(path, JSON.stringify(config, null, 2) + "\n", "utf8");
  }

  private normalizeRootDir(rootDir: string): string {
    const trimmed = rootDir.trim();
    const abs = isAbsolute(trimmed) ? trimmed : resolve(process.cwd(), trimmed);
    return resolve(abs);
  }

  private makeServerKey(server: EnriLspServerConfig): string {
    const rootKey = server.rootDir ? this.normalizeRootDir(server.rootDir) : "[auto]";
    return JSON.stringify({
      name: server.name ?? "",
      rootDir: rootKey,
      extensions: server.extensions.map((e) => e.toLowerCase()).sort(),
      command: server.command,
    });
  }

  private printHelp(): void {
    const defaultPath: string = configService.getDefaultConfigPath();
    const presets: Preset[] = presetRegistry.getPresets();
    const presetLines =
      presets.length === 0 ? "  (no presets available on this platform)" : presets.map((p) => `  - ${p.id}: ${p.label}`).join("\n");

    console.log("EnriLSP interactive menu");
    console.log("");
    console.log("Usage:");
    console.log("  enrilsp menu");
    console.log("  enrilsp menu --print-config-path");
    console.log("  enrilsp menu --help");
    console.log("");
    console.log("Default user config path:");
    console.log(`  ${defaultPath}`);
    console.log("");
    console.log("Available presets:");
    console.log(presetLines);
  }

  private getInstallersDir(): string {
    const thisDir = dirname(fileURLToPath(import.meta.url));
    return resolve(thisDir, "..", "installers");
  }

  private async runInstaller(installerScript: string): Promise<void> {
    const installersDir = this.getInstallersDir();
    const fullPath = join(installersDir, installerScript);
    if (!existsSync(fullPath)) {
      throw new Error(`Installer script not found: ${fullPath}`);
    }

    await new Promise<void>((resolvePromise, rejectPromise) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", fullPath], { stdio: "inherit" });
      child.on("exit", (code) => {
        if (code === 0) resolvePromise();
        else rejectPromise(new Error(`Installer exited with code ${code}`));
      });
      child.on("error", rejectPromise);
    });
  }

  private formatServerSummary(server: EnriLspServerConfig): string {
    const name = server.name ?? "(unnamed)";
    const root = server.rootDir ?? "[auto]";
    const exts = server.extensions.join(",");
    return `${name} [${exts}] @ ${root}`;
  }

  private async promptProjectRoot(rl: ReturnType<typeof createInterface>): Promise<string | null> {
    const defaultRoot = process.cwd();
    const answer = await rl.question(
      `Project rootDir (absolute path). Enter = current dir, or type "auto" for auto-detect [${defaultRoot}]: `
    );
    if (answer.trim().toLowerCase() === "auto") {
      return null;
    }

    const rootDir = this.normalizeRootDir(answer.trim().length > 0 ? answer : defaultRoot);
    if (!existsSync(rootDir)) {
      throw new Error(`Directory does not exist: ${rootDir}`);
    }
    return rootDir;
  }

  private async promptSelectPresets(rl: ReturnType<typeof createInterface>, presets: Preset[]): Promise<Preset[]> {
    if (presets.length === 0) return [];

    console.log("");
    console.log("Select one or more presets (comma-separated numbers):");
    presets.forEach((p, i) => console.log(`  ${i + 1}) ${p.label}  (${p.id})`));
    const raw = await rl.question("> ");
    const parts = raw
      .split(/[,\s]+/g)
      .map((p) => p.trim())
      .filter((p) => p.length > 0);

    const indexes = new Set<number>();
    for (const part of parts) {
      const n = Number.parseInt(part, 10);
      if (!Number.isFinite(n) || n < 1 || n > presets.length) {
        throw new Error(`Invalid selection: "${part}"`);
      }
      indexes.add(n - 1);
    }

    return Array.from(indexes)
      .sort((a, b) => a - b)
      .map((idx) => presets[idx]!)
      .filter(Boolean);
  }

  private findFirstFileWithExtension(rootDir: string, extension: string): string | null {
    // Keep it simple and fast: only check top-level files in rootDir.
    // This matches common ".sln in repo root" conventions.
    try {
      const entries = readdirSync(rootDir, { withFileTypes: true });
      for (const e of entries) {
        if (!e.isFile()) continue;
        if (e.name.toLowerCase().endsWith(extension.toLowerCase())) {
          return join(rootDir, e.name);
        }
      }
    } catch {
      // ignore
    }
    return null;
  }

  private async maybeAugmentCsharpLsCommand(
    rl: ReturnType<typeof createInterface>,
    rootDir: string,
    server: EnriLspServerConfig
  ): Promise<EnriLspServerConfig> {
    if ((server.name ?? "").toLowerCase() !== "csharp-ls") return server;

    // If a solution exists, prefer it for best results.
    const sln = this.findFirstFileWithExtension(rootDir, ".sln");
    if (!sln) return server;

    console.log("");
    console.log(`[csharp-ls] Found solution: ${sln}`);
    const answer = await rl.question("Pass this solution to csharp-ls via --solution? [Y/n]: ");
    if (answer.trim().length > 0 && !this.isTruthy(answer)) return server;

    // Insert before any trailing args (keep order stable).
    return {
      ...server,
      command: [...server.command, "--solution", sln],
    };
  }

  private mergeServers(config: EnriLspConfig, serversToAdd: EnriLspServerConfig[]): { added: number } {
    const existingKeys = new Set(config.servers.map((s) => this.makeServerKey(s)));
    let added = 0;
    for (const s of serversToAdd) {
      const key = this.makeServerKey(s);
      if (existingKeys.has(key)) continue;
      existingKeys.add(key);
      config.servers.push(s);
      added++;
    }
    return { added };
  }

  private removeServersByRootDir(config: EnriLspConfig, rootDir: string): number {
    const before = config.servers.length;
    if (rootDir === "[auto]") {
      config.servers = config.servers.filter((s) => !!s.rootDir);
      return before - config.servers.length;
    }

    const normalized = this.normalizeRootDir(rootDir);
    config.servers = config.servers.filter((s) => {
      if (!s.rootDir) return true;
      return this.normalizeRootDir(s.rootDir) !== normalized;
    });
    return before - config.servers.length;
  }

  private groupByRootDir(config: EnriLspConfig): Map<string, EnriLspServerConfig[]> {
    const map = new Map<string, EnriLspServerConfig[]>();
    for (const s of config.servers) {
      const root = s.rootDir ?? "[auto]";
      const list = map.get(root) ?? [];
      list.push(s);
      map.set(root, list);
    }
    return map;
  }

  public async run(argv: string[]): Promise<void> {
    if (argv.includes("--help") || argv.includes("-h")) {
      this.printHelp();
      return;
    }

    if (argv.includes("--print-config-path")) {
      console.log(configService.getDefaultConfigPath());
      return;
    }

    if (!process.stdin.isTTY || !process.stdout.isTTY) {
      console.error("[EnriLSP] Interactive menu requires a TTY.");
      console.error("[EnriLSP] Tip: run `enrilsp menu --help` for non-interactive options.");
      process.exitCode = 1;
      return;
    }

    const configPath: string = configService.getDefaultConfigPath();
    const presets: Preset[] = presetRegistry.getPresets();

    console.log(`[EnriLSP] User config path: ${configPath}`);
    console.log(`[EnriLSP] Home: ${homedir()}`);

    const rl = createInterface({ input: process.stdin, output: process.stdout });
    try {
      while (true) {
        const config = await this.readJsonConfigOrEmpty(configPath);

        console.log("");
        console.log("EnriLSP Menu");
        console.log("1) Add/install LSP preset(s) for a project");
        console.log("2) Remove all LSP entries for a project rootDir");
        console.log("3) Run installer(s) only");
        console.log("4) Show current config summary");
        console.log("5) Prune LocalAppData installs");
        console.log("6) Exit");

        const choice = (await rl.question("> ")).trim();
        if (choice === "6" || choice.toLowerCase() === "exit" || choice.toLowerCase() === "q") {
          return;
        }

      if (choice === "5") {
        const { PruneCommand } = await import("./prune.js");
        await new PruneCommand().run(["prune"]);
        continue;
      }

        if (choice === "4") {
          const grouped = this.groupByRootDir(config);
          console.log("");
          console.log(`Config entries: ${config.servers.length}`);
          for (const [root, servers] of grouped.entries()) {
            console.log(`- ${root}`);
            for (const s of servers) console.log(`  - ${this.formatServerSummary(s)}`);
          }
          continue;
        }

        if (choice === "3") {
          if (presets.length === 0) {
            console.log("No presets available on this platform.");
            continue;
          }

          const selected = await this.promptSelectPresets(rl, presets);
          const scripts = Array.from(new Set(selected.map((p) => p.installerScript).filter((s): s is string => !!s)));

          if (scripts.length === 0) {
            console.log("No installer scripts for the selected presets.");
            continue;
          }

          console.log("");
          console.log("Running installers:");
          scripts.forEach((s) => console.log(`- ${s}`));

          for (const script of scripts) {
            console.log("");
            console.log(`[EnriLSP] Running: ${script}`);
            await this.runInstaller(script);
          }

          console.log("");
          console.log("[EnriLSP] Installers completed.");
          continue;
        }

        if (choice === "2") {
          const grouped = this.groupByRootDir(config);
          const roots = Array.from(grouped.keys()).sort();
          if (roots.length === 0) {
            console.log("Config is empty.");
            continue;
          }

          console.log("");
          console.log("Select a project rootDir to remove (number):");
          roots.forEach((r, i) => console.log(`  ${i + 1}) ${r} (${grouped.get(r)?.length ?? 0} server(s))`));
          const raw = (await rl.question("> ")).trim();
          const idx = Number.parseInt(raw, 10);
          if (!Number.isFinite(idx) || idx < 1 || idx > roots.length) {
            console.log("Invalid selection.");
            continue;
          }

          const rootDir = roots[idx - 1]!;
          const matches = config.servers
            .map((s, i) => ({ server: s, index: i }))
            .filter(({ server }) => {
              if (rootDir === "[auto]") return !server.rootDir;
              if (!server.rootDir) return false;
              return this.normalizeRootDir(server.rootDir) === this.normalizeRootDir(rootDir);
            });

          if (matches.length === 0) {
            console.log("No servers found for that rootDir.");
            continue;
          }

          console.log("");
          console.log(`Servers for "${rootDir}":`);
          matches.forEach(({ server }, i) => console.log(`  ${i + 1}) ${this.formatServerSummary(server)}`));
          console.log("Type numbers to remove (comma-separated), or 'all' to remove everything for this rootDir.");
          const whichRaw = (await rl.question("> ")).trim();

          let removeAll = false;
          const toRemove = new Set<number>();
          if (whichRaw.length === 0 || whichRaw.toLowerCase() === "all") {
            removeAll = true;
          } else {
            const parts = whichRaw
              .split(/[,\s]+/g)
              .map((p) => p.trim())
              .filter((p) => p.length > 0);
            for (const part of parts) {
              const n = Number.parseInt(part, 10);
              if (!Number.isFinite(n) || n < 1 || n > matches.length) {
                console.log(`Invalid selection: "${part}"`);
                removeAll = false;
                toRemove.clear();
                break;
              }
              toRemove.add(n - 1);
            }
            if (toRemove.size === 0) {
              continue;
            }
          }

          console.log("");
          const confirm = await rl.question(
            removeAll ? `Remove ALL servers for rootDir "${rootDir}"? [y/N]: ` : `Remove ${toRemove.size} server(s) for rootDir "${rootDir}"? [y/N]: `
          );
          if (!this.isTruthy(confirm)) {
            console.log("Canceled.");
            continue;
          }

          let removed = 0;
          if (removeAll) {
            removed = this.removeServersByRootDir(config, rootDir);
          } else {
            const globalIndexes = new Set(Array.from(toRemove.values()).map((localIdx: number) => matches[localIdx]!.index));
            const before = config.servers.length;
            config.servers = config.servers.filter((_, i) => !globalIndexes.has(i));
            removed = before - config.servers.length;
          }
          const backupPath = this.backupExistingFile(configPath);
          await this.writeJsonConfig(configPath, config);

          console.log("");
          console.log(`[EnriLSP] Removed ${removed} server(s).`);
          if (backupPath) console.log(`[EnriLSP] Backup: ${backupPath}`);
          continue;
        }

        if (choice === "1") {
          if (presets.length === 0) {
            console.log("No presets available on this platform.");
            continue;
          }

          const rootDir = await this.promptProjectRoot(rl);
          const selected = await this.promptSelectPresets(rl, presets);
          if (selected.length === 0) {
            console.log("No presets selected.");
            continue;
          }

          console.log("");
          const doInstall = await rl.question("Run installers now? [Y/n]: ");
          const installNow = doInstall.trim().length === 0 || this.isTruthy(doInstall);

          if (installNow) {
            const scripts = Array.from(new Set(selected.map((p) => p.installerScript).filter((s): s is string => !!s)));
            for (const script of scripts) {
              console.log("");
              console.log(`[EnriLSP] Running: ${script}`);
              await this.runInstaller(script);
            }
            console.log("");
            console.log("[EnriLSP] Installers completed.");
          }

          let serversToAdd: EnriLspServerConfig[] = [];
          for (const preset of selected) {
            for (const serverTemplate of preset.servers) {
              if (rootDir) serversToAdd.push({ ...serverTemplate, rootDir });
              else serversToAdd.push({ ...serverTemplate });
            }
          }

          // Allow per-server best-effort augmentation without PowerShell wrappers.
          const augmented: EnriLspServerConfig[] = [];
          for (const server of serversToAdd) {
            if (rootDir) augmented.push(await this.maybeAugmentCsharpLsCommand(rl, rootDir, server));
            else augmented.push(server);
          }
          serversToAdd = augmented;

          const { added } = this.mergeServers(config, serversToAdd);
          const backupPath = this.backupExistingFile(configPath);
          await this.writeJsonConfig(configPath, config);

          console.log("");
          console.log(`[EnriLSP] Wrote config: ${configPath}`);
          if (backupPath) console.log(`[EnriLSP] Backup: ${backupPath}`);
          console.log(`[EnriLSP] Added ${added} server(s) for ${rootDir ?? "[auto]"}`);
          continue;
        }

        console.log("Unknown option.");
      }
    } finally {
      rl.close();
    }
  }
}
