import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";

// apps/<app>의 canonical surface 해시 — .activation 마커 자신은 제외한다.
// ⚠️ codex pass1 F3: apps/<app> 전체 tree-hash는 .activation을 포함해 마커 커밋 즉시 자기 무효화한다
// (정상 활성 앱이 전부 surface-drift로 오탐). marker 기록(activate-app)과 감사(audit-orphans)가
// 이 함수를 동일하게 호출해야 일치한다. rev: 커밋 ref(syncedRev 또는 "HEAD"). 실패 시 "" 반환.
export function surfaceHash(repoDir, rev, app) {
  let out;
  try {
    out = execFileSync("git", ["-C", repoDir, "ls-tree", "-r", `${rev}:apps/${app}`], { encoding: "utf8" });
  } catch {
    return "";
  }
  const lines = out.split("\n")
    .filter((l) => l && !l.endsWith("\tdeploy/prod/.activation"))
    .sort();
  return createHash("sha256").update(lines.join("\n")).digest("hex");
}

// CLI: node tools/lib/surface-hash.mjs <repoDir> <rev> <app> → 해시 출력(테스트가 동일 알고리즘 재사용).
if (process.argv[1] && process.argv[1].endsWith("surface-hash.mjs")) {
  const [repoDir, rev, app] = process.argv.slice(2);
  process.stdout.write(surfaceHash(repoDir, rev, app));
}
