import { existsSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ensureDefaultConfigDirExists, getDefaultConfigPath } from "./config.js";
import type { EnriLspConfig } from "./types.js";

function parseArgs(argv: string[]): { global: boolean; force: boolean; install: boolean } {
  const out = { global: false, force: false, install: false };
  for (const arg of argv) {
    if (arg === "--global") out.global = true;
    if (arg === "--force") out.force = true;
    if (arg === "--install") out.install = true;
  }
  return out;
}

function buildDefaultConfig(projectRoot: string): EnriLspConfig {
  const home = homedir();
  const csharpLsExe =
    process.platform === "win32"
      ? join(home, ".dotnet", "tools", "csharp-ls.exe")
      : "csharp-ls";

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

export async function main(): Promise<void> {
  const argv = process.argv.slice(3); // ["setup", ...]
  const { global, force, install } = parseArgs(argv);

  const projectRoot = resolve(process.cwd());
  const config: EnriLspConfig = buildDefaultConfig(projectRoot);

  const targetPath = global ? getDefaultConfigPath() : join(projectRoot, ".enrilsp.json");

  if (existsSync(targetPath) && !force) {
    console.error(`[enrilsp] Config already exists: ${targetPath}`);
    console.error(`[enrilsp] Use --force to overwrite.`);
    return;
  }

  if (global) {
    ensureDefaultConfigDirExists();
  }

  await writeFile(targetPath, JSON.stringify(config, null, 2) + "\n", "utf8");
  console.error(`[enrilsp] Wrote config: ${targetPath}`);

  if (install && process.platform === "win32") {
    const thisDir = dirname(fileURLToPath(import.meta.url));
    const repoRoot = resolve(thisDir, "..");
    const csharpInstaller = join(repoRoot, "installers", "check-omnisharp.ps1");

    if (!existsSync(csharpInstaller)) {
      console.error(`[enrilsp] Windows installer script not found: ${csharpInstaller}`);
      console.error(`[enrilsp] Skipping installation.`);
      return;
    }

    console.error(`[enrilsp] Installing C# dependencies via: ${csharpInstaller}`);
    await new Promise<void>((resolvePromise, rejectPromise) => {
      const child = spawn(
        "powershell.exe",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", csharpInstaller],
        { stdio: "inherit" }
      );
      child.on("exit", (code) => {
        if (code === 0) resolvePromise();
        else rejectPromise(new Error(`Installer exited with code ${code}`));
      });
      child.on("error", rejectPromise);
    });

    console.error(`[enrilsp] Install completed.`);
    return;
  }

  console.error(
    `[enrilsp] Next: install your language server (ex: csharp-ls) and start the MCP server. (Tip: run 'enrilsp setup --install' on Windows)`
  );
}
