// 실제 생성 경로의 모드를 검사한다. root/systemd 경계만 대체하므로 cgroup 수용 증거가 아니다.
import { mock } from "bun:test";
import * as fs from "node:fs";
import { join } from "node:path";
import { strict as assert } from "node:assert";

const actual = { ...fs }, observed = [], owners = new Map();
const root = actual.mkdtempSync(join(process.env.BATS_TEST_TMPDIR, "role-permissions-"));
const work = join(root, "work"), scope = process.argv[2];
const mode = path => actual.statSync(path).mode & 0o777;
const originalMkdtemp = actual.mkdtempSync;
// worker의 고정 상태 루트도 테스트 전용 디렉터리에 대응한다.
mock.module("node:fs", () => ({ ...actual,
  mkdtempSync: prefix => originalMkdtemp(String(prefix).startsWith("/run/aiops-probe-") ? join(root, "probe-") : String(prefix).replace("/var/lib/homelab-aiops/work", work)),
  mkdirSync: (path, options) => actual.mkdirSync(path === "/var/lib/homelab-aiops/work" ? work : path, options),
  chmodSync: (path, value) => actual.chmodSync(path === "/var/lib/homelab-aiops/work" ? work : path, value),
  chownSync: (path, uid, gid) => { owners.set(path, { uid, gid }); },
}));
mock.module("../../lib/exec.ts", () => ({ isolatedSpawn: () => { throw new Error("unexpected-process"); }, isolatedSpawnSync: command => ({ status: 0, stdout: command === "/usr/bin/id" ? "10001\n" : "LoadState=not-found\nActiveState=inactive\n" }) }));
process.getuid = () => 0;
process.umask(0o007);
try {
  if (scope === "probe") {
    mock.module("../../lib/aiops/process.ts", () => ({ STAGE_LIMITS: { collect: { milliseconds: 120000, memoryMiB: 512, bytes: 1048576 } }, runProcess: async command => {
      const path = command.at(-1), directory = join(path, "..");
      observed.push({ script: mode(path), directory: mode(directory), output: mode(join(directory, "output")), credential: mode(join(directory, "mock-credential")) });
      return { status: "failed", exitCode: 2, bytes: 0, stdout: "", cleanup: "confirmed" };
    } }));
    const { probeHost } = await import("../../lib/aiops/host.ts");
    const result = await probeHost();
    assert.equal(result.ready, false);
    assert.deepEqual(Object.keys(result.stages), ["role", "timeoutAndEscapedChild", "oom", "output"]);
    for (const stage of Object.values(result.stages)) assert.deepEqual(stage, { status: "failed", exitCode: 2, cleanup: "confirmed" });
    console.log(JSON.stringify(observed));
    assert.equal(observed.length, 4);
    for (const item of observed) {
      assert.equal(item.script, 0o444, "isolated UID must read the probe script");
      assert.equal(item.directory, 0o755);
      assert.equal(item.output, 0o777);
      assert.equal(item.credential, 0o600, "mock credential must remain owner-only");
    }
  } else {
    mock.module("../../lib/aiops/host.ts", () => ({ cleanUnit: () => true, readiness: () => ({ ready: true }), runHostStage: async options => {
      const input = options.command.at(-1), directory = join(input, "..");
      observed.push({ work: mode(work), attempt: mode(join(directory, "..")), job: mode(directory), input: mode(input), output: mode(options.writable.split(" ")[0]), inputOwner: owners.get(input) });
      return { status: "completed", stdout: "{}", bytes: 0, cleanup: "confirmed" };
    } }));
    const { worker } = await import("../../lib/aiops/worker.ts");
    const { AiopsError } = await import("../../lib/aiops/input.ts");
    const incidents = { budget: () => ({}), list: () => [], prune() {}, sourceHealth() {}, next() { throw new AiopsError("no-queued-incidents"); } };
    await worker(incidents, { enabled: true, installation: { bun: "/usr/bin/bun", code: "/opt/fixture" }, repository: "/repo" }, join(root, "state"));
    console.log(JSON.stringify(observed));
    assert.equal(observed.length, 1);
    assert.deepEqual(observed[0], { work: 0o711, attempt: 0o711, job: 0o711, input: 0o400, output: 0o700, inputOwner: { uid: 10001, gid: 10001 } });
  }
} finally { actual.rmSync(root, { recursive: true, force: true }); }
