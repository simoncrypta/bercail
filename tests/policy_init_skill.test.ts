import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DefaultResourceLoader, SettingsManager } from "@earendil-works/pi-coding-agent";
import { expect, test, vi } from "vite-plus/test";

test.each(["gh", "entire"])(
  "%s starter is auto-discovered only with Pi project trust and remains incomplete",
  async (backend) => {
    const box = mkdtempSync(join(tmpdir(), "policy-init-skill-"));
    try {
      const repo = join(box, "repo");
      const home = join(box, "home");
      const bin = join(box, "bin");
      mkdirSync(home);
      mkdirSync(bin);
      const calls = join(box, "unexpected-calls");
      for (const tool of ["pi", "hc", "gh", "gt", "origin", "entire", "curl", "op"]) {
        const file = join(bin, tool);
        writeFileSync(file, `#!/bin/sh\nprintf '%s\\n' '${tool}' >> '${calls}'\nexit 97\n`);
        chmodSync(file, 0o755);
      }
      const env: NodeJS.ProcessEnv = Object.fromEntries(
        Object.entries(process.env).filter(
          ([key]) => !/^(HC|HERDR|BERCAIL|BEADS|BD|GIT|HANDOFF|PI)_|^BASH_ENV$/.test(key),
        ),
      );
      Object.assign(env, {
        HOME: home,
        XDG_CONFIG_HOME: join(home, ".config"),
        XDG_STATE_HOME: join(home, ".local/state"),
        XDG_DATA_HOME: join(home, ".local/share"),
        XDG_CACHE_HOME: join(home, ".cache"),
        XDG_RUNTIME_DIR: join(box, "run"),
        TMPDIR: join(box, "tmp"),
        PI_CODING_AGENT_DIR: join(home, ".pi/agent"),
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: join(home, "gitconfig"),
        PATH: `${bin}:${(process.env.PATH ?? "")
          .split(":")
          .filter((p) => !p.endsWith("/mise/shims"))
          .join(":")}`,
        __MISE_BASH_ENV_LOADED: "1",
      });
      mkdirSync(env.XDG_RUNTIME_DIR!, { mode: 0o700 });
      mkdirSync(env.TMPDIR!);
      const git = spawnSync("git", ["init", "-q", repo], { env, encoding: "utf8" });
      expect(git.status, git.stderr).toBe(0);
      if (backend === "entire") {
        const remote = spawnSync(
          "git",
          ["-C", repo, "remote", "add", "origin", "entire://example.com/et/project/repo"],
          {
            env,
            encoding: "utf8",
          },
        );
        expect(remote.status, remote.stderr).toBe(0);
      }
      const result = spawnSync(
        resolve("bin/bercail"),
        [
          "policy",
          "init",
          "--repo",
          repo,
          "--profile",
          "guarded",
          "--backend",
          backend,
          "--verify",
          "example",
          "--write",
        ],
        { env, encoding: "utf8" },
      );
      expect(result.status, result.stderr).toBe(0);
      const skillsDir = join(repo, ".agents/skills");
      const file = join(skillsDir, "verify-example/SKILL.md");
      const discovery = spawnSync("bash", ["-c", 'ls "$1"/.agents/skills/verify-*/SKILL.md', "validate", repo], {
        env,
        encoding: "utf8",
      });
      expect(discovery.status, discovery.stderr).toBe(0);
      expect(discovery.stdout.trim()).toBe(file);
      for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
      for (const key of Object.keys(process.env)) {
        if (!(key in env) && /^(HC|HERDR|BERCAIL|BEADS|BD|GIT|HANDOFF|PI)_|^BASH_ENV$/.test(key))
          vi.stubEnv(key, undefined);
      }
      const cwd = join(repo, "subdir");
      mkdirSync(cwd);
      const settings = SettingsManager.inMemory({ packages: [] }, { projectTrusted: false });
      const loader = new DefaultResourceLoader({
        cwd,
        agentDir: env.PI_CODING_AGENT_DIR!,
        settingsManager: settings,
        noExtensions: true,
        noPromptTemplates: true,
        noThemes: true,
        noContextFiles: true,
      });
      await loader.reload();
      expect(loader.getSkills()).toEqual({ skills: [], diagnostics: [] });
      // This choice belongs only to the disposable SDK fixture; init never grants it.
      settings.setProjectTrusted(true);
      await loader.reload();
      const loaded = loader.getSkills();
      expect(loaded.diagnostics).toEqual([]);
      expect(loaded.skills.map((s) => [s.name, s.filePath])).toEqual([["verify-example", file]]);
      expect(existsSync(join(env.PI_CODING_AGENT_DIR!, "trust.json"))).toBe(false);
      const text = readFileSync(file, "utf8");
      expect(text).toMatch(/INCOMPLETE/);
      expect(text).toMatch(/stop/i);
      expect(text).toMatch(/acceptance/i);
      expect(readdirSync(join(skillsDir, "verify-example"))).toEqual(["SKILL.md"]);
      expect(existsSync(join(repo, ".bercail/validate.json"))).toBe(false);
      expect(existsSync(join(repo, ".bercail/description.md"))).toBe(false);
      expect(existsSync(join(env.XDG_STATE_HOME!, "bercail/policy-trust.json"))).toBe(false);
      expect(existsSync(calls)).toBe(false);
    } finally {
      vi.unstubAllEnvs();
      rmSync(box, { recursive: true, force: true });
    }
  },
);
