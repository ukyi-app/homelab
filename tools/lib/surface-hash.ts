import { createHash } from "node:crypto";
// 실행은 exec seam 경유(d6④) — git 실패는 ""로 흡수하는 기존 계약 유지.
import { git } from "./exec.ts";
import { readdirSync, readlinkSync, statSync } from "node:fs";
import path from "node:path";

// 공용 코어 — `git ls-tree -r`(또는 그 재구성) 라인 배열에서 canonical surface 해시를 낸다.
// ⚠️ codex pass1 F3: .activation 마커 라인은 제외한다(마커 커밋이 트리를 바꿔 자기 무효화하는 것 방지).
function hashLines(lines: string[]): string {
  const filtered = lines
    .filter((l) => l && !l.endsWith("\tdeploy/prod/.activation"))
    .sort();
  return createHash("sha256").update(filtered.join("\n")).digest("hex");
}

// apps/<app>의 canonical surface 해시 — .activation 마커 자신은 제외한다.
// ⚠️ codex pass1 F3: apps/<app> 전체 tree-hash는 .activation을 포함해 마커 커밋 즉시 자기 무효화한다
// (정상 활성 앱이 전부 surface-drift로 오탐). marker 기록(activate-app)과 감사(audit-orphans)가
// 이 함수를 동일하게 호출해야 일치한다. rev: 커밋 ref(syncedRev 또는 "HEAD"). 실패 시 "" 반환.
export function surfaceHash(repoDir: string, rev: string, app: string): string {
  // 실패는 ""로 흡수하는 계약 — seam이 stderr를 캡처만 하고 버리므로 git의 "fatal: not a git
  // repository" 등이 부모 stderr로 새지 않는다(비-git 픽스처에서 감사 출력 오염 방지).
  const r = git(repoDir, ["ls-tree", "-r", `${rev}:apps/${app}`], { timeoutMs: 0 });
  if (!r.ok) return "";
  return hashLines(r.out.split("\n"));
}

// working-tree 변형 — 아직 커밋되지 않은 apps/<app> 파일에서 canonical surface 해시를 낸다.
// create-app이 생성 시점에 .activation 마커를 남길 때 쓴다(파일은 이후 PR로 커밋된다). 각 파일의
// blob sha를 `git hash-object`로 계산해 `git ls-tree -r`의 출력 라인(`<mode> blob <sha>\t<path>`)을 그대로
// 재현하므로, 커밋 후 surfaceHash(HEAD, app)와 **동일한 값**이 된다(라이브 검증). git 레포가 아니거나
// hash-object 실패 시 "" — 마커는 registry projection만으로도 재노출 게이트에 유효하다.
export function surfaceHashWorktree(repoDir: string, app: string): string {
  const base = path.join(repoDir, "apps", app);
  const lines: string[] = [];
  const walk = (dir: string, rel: string): boolean => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return false;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        if (!walk(full, r)) return false;
      } else if (e.isSymbolicLink()) {
        // git ls-tree -r은 심볼릭 링크를 mode 120000 blob(링크 **대상 문자열**의 sha)으로 낸다 —
        // 링크를 따라가 파일 내용을 해시하면 안 된다(그러면 대상 파일이 바뀌었는데 링크 자체는
        // 그대로인 경우를 놓친다). readlink 결과를 개행 없이 그대로 hash-object --stdin에 먹인다.
        let target: string;
        try {
          target = readlinkSync(full);
        } catch {
          return false;
        }
        const h = git(repoDir, ["hash-object", "--stdin"], { timeoutMs: 0, input: target });
        if (!h.ok) return false;
        const sha = h.out.trim();
        lines.push(`120000 blob ${sha}\t${r}`);
      } else if (e.isFile()) {
        const h = git(repoDir, ["hash-object", full], { timeoutMs: 0 });
        if (!h.ok) return false;
        const sha = h.out.trim();
        // git ls-tree는 실행권 있으면 100755, 아니면 100644 — create-app 산출물은 전부 비실행(644).
        const mode = statSync(full).mode & 0o111 ? "100755" : "100644";
        lines.push(`${mode} blob ${sha}\t${r}`);
      } else {
        // FIFO·소켓 등 그 외 엔트리 유형 — 헤더(:31) 계약대로 fail-loud("" 반환)로 처리한다.
        // 조용히 건너뛰면(누락) 이번 finding과 같은 값 발산이 다른 엔트리 유형에서 재발한다.
        return false;
      }
    }
    return true;
  };
  if (!walk(base, "")) return "";
  return hashLines(lines);
}

// CLI: bun tools/lib/surface-hash.ts <repoDir> <rev> <app> → 해시 출력(테스트가 동일 알고리즘 재사용).
if (process.argv[1] && process.argv[1].endsWith("surface-hash.ts")) {
  const [repoDir, rev, app] = process.argv.slice(2);
  process.stdout.write(surfaceHash(repoDir, rev, app));
}
