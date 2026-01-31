import { existsSync, readFileSync } from "node:fs";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

import type { EnriLspConfig } from "./types.js";

const ENV_CONFIG_PATH = "ENRILSP_CONFIG_PATH";

export function getDefaultConfigPath(): string {
  if (process.platform === "win32") {
    const base =
      process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
    return join(base, "EnriLSP", "enrilsp.json");
  }

  const base = process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config");
  return join(base, "enrilsp", "enrilsp.json");
}

export function findConfigPath(): string | undefined {
  const envPath = process.env[ENV_CONFIG_PATH];
  if (envPath && envPath.trim().length > 0) {
    return resolve(envPath);
  }

  const defaultPath = getDefaultConfigPath();
  if (existsSync(defaultPath)) {
    return defaultPath;
  }

  const cwd = process.cwd();
  const candidates = [
    join(cwd, ".enrilsp.json"),
    join(cwd, "enrilsp.json"),
  ];

  for (const p of candidates) {
    if (existsSync(p)) return p;
  }

  return undefined;
}

export function loadConfigOrThrow(): EnriLspConfig {
  const configPath = findConfigPath();
  if (!configPath) {
    const hint =
      process.platform === "win32"
        ? `Run: enrilsp setup (or set %${ENV_CONFIG_PATH}%)`
        : `Run: enrilsp setup (or set $${ENV_CONFIG_PATH})`;
    throw new Error(
      `EnriLSP config not found. Expected at ${getDefaultConfigPath()} or in the current directory as .enrilsp.json.\n${hint}`
    );
  }

  let raw: string;
  try {
    raw = readFileSync(configPath, "utf8");
  } catch (error) {
    throw new Error(`Failed to read config file at ${configPath}: ${error}`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid JSON in config file ${configPath}: ${error}`);
  }

  if (!parsed || typeof parsed !== "object") {
    throw new Error(`Invalid config file ${configPath}: expected a JSON object`);
  }

  const config = parsed as Partial<EnriLspConfig>;
  if (!Array.isArray(config.servers)) {
    throw new Error(
      `Invalid config file ${configPath}: expected { \"servers\": [...] }`
    );
  }

  return config as EnriLspConfig;
}

export function ensureDefaultConfigDirExists(): void {
  const configPath = getDefaultConfigPath();
  const dir = resolve(dirname(configPath));
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}
