import { existsSync, readFileSync } from "node:fs";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

import type { EnriLspConfig } from "./types.js";

export class ConfigService {
  private readonly envConfigPathKey: string = "ENRILSP_CONFIG_PATH";

  public getDefaultConfigPath(): string {
    // Enri-standard user config location (Windows/macOS/Linux):
    //   ~/.Enri/EnriLSP/Config.json
    return join(homedir(), ".Enri", "EnriLSP", "Config.json");
  }

  public findConfigPath(): string | undefined {
    const envPath = process.env[this.envConfigPathKey];
    if (envPath && envPath.trim().length > 0) {
      return resolve(envPath);
    }

    const cwd = process.cwd();
    const candidates = [join(cwd, ".enrilsp.json"), join(cwd, "enrilsp.json")];

    for (const p of candidates) {
      if (existsSync(p)) return p;
    }

    const defaultPath = this.getDefaultConfigPath();
    if (existsSync(defaultPath)) {
      return defaultPath;
    }

    return undefined;
  }

  public loadConfigOrThrow(): EnriLspConfig {
    const configPath = this.findConfigPath();
    if (!configPath) {
      const hint =
        process.platform === "win32"
          ? `Run: enrilsp menu (or set %${this.envConfigPathKey}%)`
          : `Run: enrilsp menu (or set $${this.envConfigPathKey})`;
      throw new Error(
        `EnriLSP config not found. Expected at ${this.getDefaultConfigPath()} or in the current directory as .enrilsp.json / enrilsp.json.\n${hint}`
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
      throw new Error(`Invalid config file ${configPath}: expected { \"servers\": [...] }`);
    }

    return config as EnriLspConfig;
  }

  public ensureDefaultConfigDirExists(): void {
    const configPath = this.getDefaultConfigPath();
    const dir = resolve(dirname(configPath));
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }
}

export const configService: ConfigService = new ConfigService();
