import { homedir } from "node:os";
import { join } from "node:path";

import type { EnriLspServerConfig } from "./types.js";

export interface Preset {
  /**
   * Stable identifier used by the CLI/menu.
   */
  id: string;
  /**
   * Friendly label shown to the user.
   */
  label: string;
  /**
   * Installer script (relative to the repo installers/ dir), if available.
   */
  installerScript?: string;
  /**
   * One or more server configs added when enabling this preset.
   * `rootDir` is set by the CLI at install time.
   */
  servers: Omit<EnriLspServerConfig, "rootDir">[];
}

export class PresetRegistry {
  private getWindowsRoamingAppData(): string {
    return process.env.APPDATA ?? join(homedir(), "AppData", "Roaming");
  }

  private getWindowsLocalAppData(): string {
    return process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
  }

  private getWindowsUserProfile(): string {
    return process.env.USERPROFILE ?? homedir();
  }

  public getPresets(): Preset[] {
    if (process.platform !== "win32") return [];

    const roaming = this.getWindowsRoamingAppData();
    const local = this.getWindowsLocalAppData();
    const user = this.getWindowsUserProfile();

    const npmBin = join(roaming, "npm");
    const npmNodeModules = join(roaming, "npm", "node_modules");

    const enriBin = join(local, "EnriLSP", "bin");
    const cmakeLsExe = join(local, "EnriLSP", "cmake-language-server", ".venv", "Scripts", "cmake-language-server.exe");

    const powerShellEditorServicesRoot = join(local, "EnriLSP", "PowerShellEditorServices", "PowerShellEditorServices");
    const powerShellEditorServicesStart = join(powerShellEditorServicesRoot, "Start-EditorServices.ps1");

    const luaLanguageServerExe = join(local, "EnriLSP", "lua-language-server", "bin", "lua-language-server.exe");

    return [
    {
      id: "csharp-ls",
      label: "C# / .NET (csharp-ls)",
      installerScript: "check-omnisharp.ps1",
      servers: [
        {
          name: "csharp-ls",
          extensions: ["cs", "csx"],
          command: [join(user, ".dotnet", "tools", "csharp-ls.exe"), "--stdio", "--loglevel", "error"],
          warmupMs: 500,
        },
      ],
    },
    {
      id: "angular-language-server",
      label: "Angular (ngserver)",
      installerScript: "check-angular-language-server.ps1",
      servers: [
        {
          name: "angular-language-server",
          extensions: ["ts", "html"],
          command: [
            "cmd.exe",
            "/c",
            join(npmBin, "ngserver.cmd"),
            "--stdio",
            "--tsProbeLocations",
            npmNodeModules,
            "--ngProbeLocations",
            npmNodeModules,
          ],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "astro-language-server",
      label: "Astro (@astrojs/language-server)",
      installerScript: "check-astro-language-server.ps1",
      servers: [
        {
          name: "astro-language-server",
          extensions: ["astro"],
          command: ["cmd.exe", "/c", join(npmBin, "astro-ls.cmd"), "--stdio"],
          initializationOptions: {
            typescript: { tsdk: join(npmNodeModules, "typescript", "lib") },
          },
          warmupMs: 0,
        },
      ],
    },
    {
      id: "bash-language-server",
      label: "Bash (bash-language-server)",
      installerScript: "check-bash-language-server.ps1",
      servers: [
        {
          name: "bash-language-server",
          extensions: ["sh", "bash", "zsh"],
          command: ["cmd.exe", "/c", join(npmBin, "bash-language-server.cmd"), "start"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "clangd",
      label: "C/C++ (clangd)",
      installerScript: "check-clangd.ps1",
      servers: [
        {
          name: "clangd",
          extensions: ["c", "h", "cpp", "cc", "cxx", "hpp", "hxx"],
          command: ["clangd", "--background-index"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "cmake-language-server",
      label: "CMake (cmake-language-server)",
      installerScript: "check-cmake-language-server.ps1",
      servers: [
        {
          name: "cmake-language-server",
          extensions: ["cmake"],
          command: [cmakeLsExe],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "cssmodules-language-server",
      label: "CSS Modules (cssmodules-language-server)",
      installerScript: "check-cssmodules-language-server.ps1",
      servers: [
        {
          name: "cssmodules-language-server",
          // Use compound extensions to avoid hijacking plain CSS when users also enable
          // the regular CSS language server (VSCode or others).
          extensions: ["module.css", "module.scss", "module.less", "module.sass"],
          command: ["cmd.exe", "/c", join(npmBin, "cssmodules-language-server.cmd")],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "dart-analyzer",
      label: "Dart/Flutter (dart language-server)",
      installerScript: "check-dart-analyzer.ps1",
      servers: [
        {
          name: "dart-analyzer",
          extensions: ["dart"],
          command: ["dart", "language-server", "--protocol=lsp"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "dockerfile-language-server",
      label: "Dockerfile (docker-langserver)",
      installerScript: "check-dockerfile-language-server.ps1",
      servers: [
        {
          name: "dockerfile-language-server",
          extensions: ["dockerfile", "Dockerfile"],
          command: ["cmd.exe", "/c", join(npmBin, "docker-langserver.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "ember-language-server",
      label: "Ember (ember-language-server)",
      installerScript: "check-ember-language-server.ps1",
      servers: [
        {
          name: "ember-language-server",
          extensions: ["hbs", "js", "ts"],
          command: ["cmd.exe", "/c", join(npmBin, "ember-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "gopls",
      label: "Go (gopls)",
      installerScript: "check-gopls.ps1",
      servers: [
        {
          name: "gopls",
          extensions: ["go", "mod", "sum"],
          command: ["gopls", "serve"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "graphql-lsp",
      label: "GraphQL (graphql-lsp)",
      installerScript: "check-graphql-lsp.ps1",
      servers: [
        {
          name: "graphql-lsp",
          extensions: ["graphql", "gql"],
          command: ["cmd.exe", "/c", join(npmBin, "graphql-lsp.cmd"), "server", "-m", "stream"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "intelephense",
      label: "PHP (intelephense)",
      installerScript: "check-intelephense.ps1",
      servers: [
        {
          name: "intelephense",
          extensions: ["php", "phtml"],
          command: ["cmd.exe", "/c", join(npmBin, "intelephense.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "jdtls",
      label: "Java (jdtls)",
      installerScript: "check-jdtls.ps1",
      servers: [
        {
          name: "jdtls",
          extensions: ["java"],
          command: ["cmd.exe", "/c", join(local, "EnriLSP", "jdtls", "bin", "jdtls.bat")],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "kotlin-language-server",
      label: "Kotlin (kotlin-lsp)",
      installerScript: "check-kotlin-language-server.ps1",
      servers: [
        {
          name: "kotlin-language-server",
          extensions: ["kt", "kts"],
          command: ["cmd.exe", "/c", join(local, "EnriLSP", "kotlin-lsp", "kotlin-lsp.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "lua-language-server",
      label: "Lua (lua-language-server)",
      installerScript: "check-lua-language-server.ps1",
      servers: [
        {
          name: "lua-language-server",
          extensions: ["lua"],
          command: [luaLanguageServerExe, "--locale=en-us"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "marksman",
      label: "Markdown (marksman)",
      installerScript: "check-marksman.ps1",
      servers: [
        {
          name: "marksman",
          extensions: ["md"],
          command: [join(enriBin, "marksman.exe"), "server"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "postgres-language-server",
      label: "PostgreSQL (postgres-language-server)",
      installerScript: "check-postgres-language-server.ps1",
      servers: [
        {
          name: "postgres-language-server",
          extensions: ["sql", "pgsql"],
          command: [join(enriBin, "postgres-language-server.exe"), "lsp-proxy"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "powershell-editor-services",
      label: "PowerShell (PowerShellEditorServices)",
      installerScript: "check-powershell-editor-services.ps1",
      servers: [
        {
          name: "powershell-editor-services",
          extensions: ["ps1", "psm1", "psd1"],
          command: [
            "pwsh",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            powerShellEditorServicesStart,
            "-HostName",
            "EnriLSP",
            "-HostProfileId",
            "enrilsp",
            "-HostVersion",
            "0.1.0",
            "-BundledModulesPath",
            powerShellEditorServicesRoot,
            "-Stdio",
          ],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "prisma-language-server",
      label: "Prisma (prisma-language-server)",
      installerScript: "check-prisma-language-server.ps1",
      servers: [
        {
          name: "prisma-language-server",
          extensions: ["prisma"],
          command: ["cmd.exe", "/c", join(npmBin, "prisma-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "pyright",
      label: "Python (pyright-langserver)",
      installerScript: "check-pyright.ps1",
      servers: [
        {
          name: "pyright",
          extensions: ["py", "pyi"],
          command: ["cmd.exe", "/c", "pyright-langserver", "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "rust-analyzer",
      label: "Rust (rust-analyzer)",
      installerScript: "check-rust-analyzer.ps1",
      servers: [
        {
          name: "rust-analyzer",
          extensions: ["rs"],
          command: ["rust-analyzer"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "solargraph",
      label: "Ruby (solargraph)",
      installerScript: "check-solargraph.ps1",
      servers: [
        {
          name: "solargraph",
          extensions: ["rb", "rake", "gemspec"],
          command: ["cmd.exe", "/c", "solargraph", "stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "svelte-language-server",
      label: "Svelte (svelteserver)",
      installerScript: "check-svelte-language-server.ps1",
      servers: [
        {
          name: "svelte-language-server",
          extensions: ["svelte"],
          command: ["cmd.exe", "/c", join(npmBin, "svelteserver.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "tailwindcss-language-server",
      label: "Tailwind CSS (tailwindcss-language-server)",
      installerScript: "check-tailwindcss-language-server.ps1",
      servers: [
        {
          name: "tailwindcss-language-server",
          extensions: ["css", "html", "jsx", "tsx", "vue"],
          command: ["cmd.exe", "/c", join(npmBin, "tailwindcss-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "terraform-ls",
      label: "Terraform (terraform-ls)",
      installerScript: "check-terraform-ls.ps1",
      servers: [
        {
          name: "terraform-ls",
          extensions: ["tf", "tfvars"],
          command: [join(enriBin, "terraform-ls.exe"), "serve"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "texlab",
      label: "LaTeX (texlab)",
      installerScript: "check-texlab.ps1",
      servers: [
        {
          name: "texlab",
          extensions: ["tex", "bib"],
          command: [join(enriBin, "texlab.exe")],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "vscode-langservers",
      label: "VSCode web language servers (html/css/json/eslint)",
      installerScript: "check-vscode-langservers.ps1",
      servers: [
        {
          name: "vscode-html-language-server",
          extensions: ["html", "htm"],
          command: ["cmd.exe", "/c", join(npmBin, "vscode-html-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
        {
          name: "vscode-css-language-server",
          extensions: ["css", "scss", "less"],
          command: ["cmd.exe", "/c", join(npmBin, "vscode-css-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
        {
          name: "vscode-json-language-server",
          extensions: ["json", "jsonc"],
          command: ["cmd.exe", "/c", join(npmBin, "vscode-json-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
        {
          name: "vscode-eslint-language-server",
          extensions: ["js", "jsx", "ts", "tsx"],
          command: ["cmd.exe", "/c", join(npmBin, "vscode-eslint-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "vtsls",
      label: "TypeScript/JavaScript (vtsls)",
      installerScript: "check-vtsls.ps1",
      servers: [
        {
          name: "vtsls",
          extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
          command: ["cmd.exe", "/c", join(npmBin, "vtsls.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "vue-language-server",
      label: "Vue (vue-language-server)",
      installerScript: "check-vue-language-server.ps1",
      servers: [
        {
          name: "vue-language-server",
          extensions: ["vue"],
          command: ["cmd.exe", "/c", join(npmBin, "vue-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "yaml-language-server",
      label: "YAML (yaml-language-server)",
      installerScript: "check-yaml-language-server.ps1",
      servers: [
        {
          name: "yaml-language-server",
          extensions: ["yaml", "yml"],
          command: ["cmd.exe", "/c", join(npmBin, "yaml-language-server.cmd"), "--stdio"],
          warmupMs: 0,
        },
      ],
    },
    {
      id: "zls",
      label: "Zig (zls)",
      installerScript: "check-zls.ps1",
      servers: [
        {
          name: "zls",
          extensions: ["zig"],
          command: [join(enriBin, "zls.exe")],
          warmupMs: 0,
        },
      ],
    },
    ];
  }
}

export const presetRegistry: PresetRegistry = new PresetRegistry();
