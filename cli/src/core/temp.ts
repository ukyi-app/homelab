// 이 실행이 만든 임시 폴더. 끝날 때 모두 지운다(정상, 실패 exit, 잡히지 않은 예외, SIGINT·SIGTERM·SIGHUP).
// tools/ci/lib.ts의 tempDir과 같은 방식이다. 함정: terraform 사본은 개당 수백 MB라 남기면 tmpfs 할당량을 넘긴다(2026-10-21 실측).
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const temps = new Set<string>();
let installed = false;

export function removeTempDirs(): void {
  for (const d of temps) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      // 정리 실패가 결과를 바꾸지 않게 한다. 남은 폴더는 이름(homelab-cli-*)으로 찾을 수 있다.
    }
  }
  temps.clear();
}

function install(): void {
  if (installed) return;
  installed = true;
  process.on("exit", removeTempDirs);
  // 신호 처리기를 달면 기본 종료가 사라지므로 직접 128+신호 번호로 끝낸다.
  for (const [sig, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]] as const) {
    process.on(sig, () => {
      removeTempDirs();
      process.exit(code);
    });
  }
}

export function tempDir(prefix: string): string {
  install();
  const d = mkdtempSync(join(tmpdir(), `homelab-cli-${prefix}-`));
  temps.add(d);
  return d;
}
