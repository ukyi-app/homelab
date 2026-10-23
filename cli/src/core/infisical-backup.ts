// Infisical CLI 로컬 백업 막기(#873 Connector P1, 사용자 결정 2026-10-23). tools/tf-github.sh·infra/README.md 2절과 같은 방식이다.
// 함정: 로그인 사용자의 CLI 0.44.2가 조회한 값을 $HOME/.infisical/secrets-backup/에 파일로 남긴다(packages/util/secrets.go
// WriteBackupSecrets, 폴더는 os.UserHomeDir() 기준이라 자식의 HOME). 호출부가 그 쓰기 오류를 무시하므로 폴더를 쓰기 불가로
// 두어 파일을 못 만들게 하고, 실제로 쓰기 불가인지 확인하고, 호출마다 파일이 0개인지 본다. 하나라도 어긋나면 실패한다.
// plan에서도 돈다. 바꾸는 것은 이 로컬 폴더의 권한과 남은 백업 파일뿐이다(Git·Infisical·클러스터는 그대로).
// exec.ts가 infisical 호출마다 부른다(호출하는 어댑터가 무엇이든 빠지지 않게).
import { chmodSync, lstatSync, mkdirSync, readdirSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { CliError } from "./result";

const NEXT = "~/.infisical/secrets-backup을 지우고(또는 권한을 지원하는 파일시스템의 HOME에서) 같은 명령을 다시 실행한다";

// 시험 전용 seam: chmod가 듣지 않는 파일시스템을 흉내 낸다. 실제 실행은 기본값만 쓴다.
export type BackupOps = { chmod: (path: string, mode: number) => void };
const realOps: BackupOps = { chmod: chmodSync };

// 준비를 마친 폴더. 한 실행에서 한 번만 비우고 잠근다(뒤 호출은 파일 0개만 본다, 래퍼와 같음).
const prepared = new Set<string>();

function entries(dir: string): string[] {
  return readdirSync(dir);
}

function wipe(dir: string, ops: BackupOps): void {
  ops.chmod(dir, 0o700);
  for (const name of entries(dir)) rmSync(join(dir, name), { recursive: true, force: true });
  ops.chmod(dir, 0o500);
}

export function backupDir(home: string | undefined): string {
  if (!home || !isAbsolute(home)) throw new CliError("HOME이 없거나 절대 경로가 아니라 Infisical 백업 폴더를 막을 수 없다", "HOME을 절대 경로로 둔 셸에서 다시 실행한다");
  return join(home, ".infisical", "secrets-backup");
}

function prepare(dir: string, ops: BackupOps): void {
  mkdirSync(dirname(dir), { recursive: true, mode: 0o700 });
  let st: ReturnType<typeof lstatSync> | undefined;
  try {
    st = lstatSync(dir);
  } catch {
    st = undefined;
  }
  // 심볼릭 링크면 chmod가 링크 너머를 바꾸고 백업은 다른 곳에 쌓인다. lstat이라 링크는 폴더가 아니다(따라가지 않고 멈춘다).
  if (st && !st.isDirectory()) throw new CliError("Infisical 백업 경로가 폴더가 아니다(심볼릭 링크 포함)", NEXT);
  if (st) wipe(dir, ops);
  else {
    mkdirSync(dir, { mode: 0o700 });
    ops.chmod(dir, 0o500);
  }
  // 권한을 지원하지 않는 파일시스템이거나 root면 0500이어도 쓸 수 있다. 실제로 써 보고 되면 멈춘다.
  const probe = join(dir, ".probe");
  let writable = false;
  try {
    writeFileSync(probe, "", { flag: "wx" });
    writable = true;
  } catch {
    writable = false;
  }
  if (writable) {
    unlinkSync(probe);
    throw new CliError("Infisical 백업 폴더가 쓰기 가능하다(조회 값이 파일로 남을 수 있다)", NEXT);
  }
}

// infisical 호출 하나를 감싼다. 호출 전 준비(처음 한 번), 호출 뒤 파일 0개 확인. 생겼으면 지우고 실패한다.
export function guardInfisicalBackup<T>(home: string | undefined, run: () => T, ops: BackupOps = realOps): T {
  const dir = backupDir(home);
  if (!prepared.has(dir)) {
    prepare(dir, ops);
    prepared.add(dir);
  }
  try {
    return run();
  } finally {
    if (entries(dir).length !== 0) {
      wipe(dir, ops);
      // 같은 실행의 다음 조회도 처음부터 다시 준비하게 한다(권한이 풀렸을 수 있다).
      prepared.delete(dir);
      // 백업이 생긴 호출의 결과는 쓰지 않는다(호출 자체의 오류보다 이 실패가 앞선다).
      throw new CliError("Infisical 백업 파일이 생겼다. 지우고 중단한다", NEXT);
    }
  }
}

// 시험 전용: 준비 기록을 비운다(cli/test/setup.ts).
export function resetBackupGuardForTests(): void {
  prepared.clear();
}
