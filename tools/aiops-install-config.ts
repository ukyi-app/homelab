// 설치 셸의 구조 데이터 처리는 타입 검사되는 이 진입점에서만 한다.
import { chownSync, chmodSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isolatedSpawnSync } from "./lib/exec.ts";
import { AiopsError, readBounded, record, requireCondition } from "./lib/aiops/input.ts";
import { digest } from "./lib/aiops/git.ts";

try {
  const [action, path, revision, release] = process.argv.slice(2);
  requireCondition(["check", "write"].includes(action) && path, "invalid-install-config-arguments");
  const config = record(JSON.parse(readBounded(path)));
  requireCondition(config.enabled === false && config.mode === "codex" && config.authentication === "/var/lib/homelab-aiops/auth" && config.repository === "/var/lib/homelab-aiops/repository", "invalid-disabled-install-config");
  if (action === "write") {
    requireCondition(process.getuid?.() === 0 && /^[a-f0-9]{40}$/.test(revision) && release === `/opt/homelab-aiops/${revision}`, "invalid-install-release");
    const binary = (name: string) => join(release, "bin", name);
    config.installation = { code: release, bun: binary("bun"), engine: binary("codex"), conftest: binary("conftest"), hashes: Object.fromEntries(["bun", "engine", "conftest"].map(name => [name, digest(readFileSync(binary(name === "engine" ? "codex" : name)))])) };
    config.installationRevision = revision;
    writeFileSync(path, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
    chmodSync(path, 0o600);
    const publication = record(config.publication);
    const roles = {
      collector: Object.fromEntries(["mode", "ingress", "github", "healthchecks", "collection"].map(name => [name, config[name]])),
      fork: { repository: publication.fork, tokenFile: publication.forkTokenFile },
      pr: { repository: publication.upstream, tokenFile: publication.prTokenFile, forkOwner: String(publication.fork).split("/")[0] },
      telegram: config.telegram,
    };
    for (const [role, value] of Object.entries(roles)) {
      const group = isolatedSpawnSync("/usr/bin/id", ["-g", `aiops-${role}`], { encoding: "utf8", timeout: 5000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin" } });
      requireCondition(group.status === 0 && /^\d+$/.test(group.stdout.trim()), "role-group-missing");
      const destination = `/etc/homelab-aiops/${role}.json`;
      writeFileSync(destination, JSON.stringify(value, null, 2) + "\n", { mode: 0o640 });
      chmodSync(destination, 0o640); chownSync(destination, 0, Number(group.stdout.trim()));
    }
  }
  console.log(JSON.stringify({ status: "configured", enabled: false }));
} catch (error) {
  console.error(JSON.stringify({ error: error instanceof AiopsError ? error.code : "install-config-failed" }));
  process.exitCode = 1;
}
