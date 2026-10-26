import { chmodSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

// 시험 HOME의 Infisical 백업 폴더는 0500이다(core/infisical-backup.ts). 안에 파일이 남으면(돌연변이 확인 등) 그냥은 못 지우므로
// 권한을 풀고 다시 지운다.
export function removeTree(dir: string): void {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    const open = (d: string) => {
      chmodSync(d, 0o700);
      for (const e of readdirSync(d, { withFileTypes: true })) if (e.isDirectory()) open(join(d, e.name));
    };
    open(dir);
    rmSync(dir, { recursive: true, force: true });
  }
}
