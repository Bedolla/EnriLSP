import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { configService } from "./config.js";
import type { EnriLspConfig } from "./types.js";

type SetupArgs = { global: boolean; force: boolean; install: boolean; help: boolean };

export class SetupCommand {
  private printHelp(): void {
    console.log("EnriLSP setup");
    console.log("");
    console.log("Creates a minimal EnriLSP config file for the current project.");
    console.log("");
    console.log("Usage:");
    console.log("  enrilsp setup");
    console.log("  enrilsp setup --force");
    console.log("  enrilsp setup --global");
    console.log("  enrilsp setup --install        (Windows only)");
    console.log("  enrilsp setup --help");
    console.log("");
    console.log("Notes:");
    console.log(`- Default output (project-local): ${join(resolve(process.cwd()), ".enrilsp.json")}`);
    console.log(`- Global output: ${configService.getDefaultConfigPath()}`);
  }

  private parseArgs(argv: string[]): SetupArgs {
    const out: SetupArgs = { global: false, force: false, install: false, help: false };
    for (const arg of argv) {
      if (arg === "--help" || arg === "-h") out.help = true;
      if (arg === "--global") out.global = true;
      if (arg === "--force") out.force = true;
      if (arg === "--install") out.install = true;
    }
    return out;
  }

  private buildDefaultConfig(projectRoot: string): EnriLspConfig {
    const home = homedir();
    const csharpLsExe = process.platform === "win32" ? join(home, ".dotnet", "tools", "csharp-ls.exe") : "csharp-ls";

    return {
      servers: [
        {
          name: "csharp-ls",
          extensions: ["cs", "csx"],
          command: [csharpLsExe, "--stdio"],
          rootDir: projectRoot,
          warmupMs: 500,
        },
      ],
    };
  }

  private async runWindowsCsharpInstaller(): Promise<void> {
    const thisDir = dirname(fileURLToPath(import.meta.url));
    const repoRoot = resolve(thisDir, "..");
    const csharpInstaller = join(repoRoot, "installers", "check-omnisharp.ps1");

    if (!existsSync(csharpInstaller)) {
      console.error(`[EnriLSP] Windows installer script not found: ${csharpInstaller}`);
      console.error(`[EnriLSP] Skipping installation.`);
      return;
    }

    console.error(`[EnriLSP] Installing C# dependencies via: ${csharpInstaller}`);
    await new Promise<void>((resolvePromise, rejectPromise) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", csharpInstaller], { stdio: "inherit" });
      child.on("exit", (code) => {
        if (code === 0) resolvePromise();
        else rejectPromise(new Error(`Installer exited with code ${code}`));
      });
      child.on("error", rejectPromise);
    });
    console.error(`[EnriLSP] Install completed.`);
  }

  public async run(argv: string[]): Promise<void> {
    const { global, force, install, help } = this.parseArgs(argv);

    if (help) {
      this.printHelp();
      return;
    }

    const projectRoot = resolve(process.cwd());
    const config: EnriLspConfig = this.buildDefaultConfig(projectRoot);

    const targetPath = global ? configService.getDefaultConfigPath() : join(projectRoot, ".enrilsp.json");

    if (existsSync(targetPath) && !force) {
      console.error(`[EnriLSP] Config already exists: ${targetPath}`);
      console.error(`[EnriLSP] Use --force to overwrite.`);
      return;
    }

    if (global) {
      configService.ensureDefaultConfigDirExists();
    }

    await writeFile(targetPath, JSON.stringify(config, null, 2) + "\n", "utf8");
    console.error(`[EnriLSP] Wrote config: ${targetPath}`);

    if (install && process.platform === "win32") {
      await this.runWindowsCsharpInstaller();
      return;
    }

    console.error(
      `[EnriLSP] Next: install your language server (ex: csharp-ls) and start the MCP server. (Tip: run 'enrilsp setup --install' on Windows)`
    );
  }
}
