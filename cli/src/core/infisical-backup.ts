// Infisical CLI 로컬 백업 막기(#873 Connector P1, 사용자 결정 2026-10-23). tools/tf-github.sh·infra/README.md 2절과 같은 목적이다.
// 함정: 로그인 사용자의 CLI 0.44.2가 조회한 값을 $HOME/.infisical/secrets-backup/에 파일로 남긴다(packages/util/secrets.go
// WriteBackupSecrets, 폴더는 os.UserHomeDir() 기준이라 자식의 HOME). 호출부가 그 쓰기 오류를 무시하므로 폴더를 쓰기 불가로
// 두어 파일을 못 만들게 하고, 실제로 쓰기 불가인지 확인하고, 호출마다 파일이 0개인지 본다. 하나라도 어긋나면 실패한다.
// plan에서도 돈다. 바꾸는 것은 이 로컬 폴더의 권한과 남은 백업 파일뿐이다(Git·Infisical·클러스터는 그대로).
// exec.ts가 infisical 호출마다 부른다(호출하는 어댑터가 무엇이든 빠지지 않게).
//
// 백업 경로는 한 번도 다시 열지 않는다(#876 리뷰 P2 둘). 래퍼처럼 0700으로 열고 비운 뒤 잠그면, 같은 HOME의 다른 실행이 그 틈에
// 백업을 쓰고 이쪽 정리가 흔적을 지워 둘 다 성공하거나, 삭제가 실패하면 열린 채 남는다. 그래서 비울 때는 폴더째 옆 이름으로
// 옮기고(부모 쓰기 권한만 필요) 처음부터 0500인 새 폴더를 만든 뒤, 옮긴 폴더를 지운다. 지우기에 실패해도 백업 경로는 잠겨 있다.
import { chmodSync, lstatSync, mkdirSync, readdirSync, realpathSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { CliError } from "./result";

const NEXT = "~/.infisical/secrets-backup*을 지우고(또는 권한을 지원하는 파일시스템의 HOME에서) 같은 명령을 다시 실행한다";
const STALE = "secrets-backup.stale-";

// 시험 전용 seam: 권한이 듣지 않는 파일시스템을 흉내 낸다. 실제 실행은 기본값만 쓴다.
export type BackupOps = { mkdirLocked: (path: string) => void; removeTree: (path: string) => void };

// 옮긴 폴더 지우기. 안쪽 0500 폴더도 열어야 지워진다(예: 이전 실행이 남긴 잠긴 폴더). 백업 경로가 아니라 열어도 된다.
function removeTree(path: string): void {
  const open = (d: string) => {
    chmodSync(d, 0o700);
    for (const e of readdirSync(d, { withFileTypes: true })) if (e.isDirectory()) open(join(d, e.name));
  };
  open(path);
  rmSync(path, { recursive: true, force: true });
}

const realOps: BackupOps = { mkdirLocked: (p) => mkdirSync(p, { mode: 0o500 }), removeTree };

// 준비를 마친 폴더. 한 실행에서 한 번만 준비한다(뒤 호출은 파일 0개만 본다, 래퍼와 같음).
const prepared = new Set<string>();

function entries(dir: string): string[] {
  return readdirSync(dir);
}

// HOME을 실제 경로로 푼다. 자식에게도 이 값을 HOME으로 준다(exec.ts). 함정(#876 리뷰 P2): path.join은 링크를 보기 전에
// `link/..`를 지워 다른 폴더를 가리키지만, Infisical은 HOME 문자열에 이어 붙여 OS가 링크를 따라간 뒤 ..를 푼다.
// Bun의 realpathSync(.native 포함)도 ..를 먼저 문자열로 지운다(1.4.3 실측). 그래서 .·.. 성분이 있는 HOME은 거부하고,
// 남은 링크만 realpath로 푼다(..가 없으면 문자열 해석과 OS 해석이 같다).
export function realHome(home: string | undefined): string {
  if (!home || !isAbsolute(home)) throw new CliError("HOME이 없거나 절대 경로가 아니라 Infisical 백업 폴더를 막을 수 없다", "HOME을 절대 경로로 둔 셸에서 다시 실행한다");
  if (home.split("/").some((part) => part === "." || part === "..")) throw new CliError("HOME에 . 또는 .. 성분이 있어 Infisical이 쓸 폴더를 정할 수 없다", "HOME을 .·.. 없는 절대 경로로 둔 셸에서 다시 실행한다");
  try {
    return realpathSync(home);
  } catch {
    throw new CliError("HOME 폴더를 찾지 못해 Infisical 백업 폴더를 막을 수 없다", "HOME을 있는 폴더로 둔 셸에서 다시 실행한다");
  }
}

function removeStale(path: string, ops: BackupOps): void {
  try {
    ops.removeTree(path);
  } catch {
    throw new CliError(`옮겨 둔 Infisical 백업을 지우지 못했다(${path}). 백업 경로는 잠겨 있다`, NEXT);
  }
}

// 백업 경로를 비운 0500 폴더로 바꾼다. 경로가 열리는 순간이 없다.
function replaceLocked(base: string, dir: string, ops: BackupOps): void {
  const stale = join(base, `${STALE}${process.pid}-${crypto.randomUUID()}`);
  renameSync(dir, stale);
  ops.mkdirLocked(dir);
  removeStale(stale, ops);
}

function prepare(home: string, ops: BackupOps): void {
  const base = join(home, ".infisical");
  mkdirSync(base, { recursive: true, mode: 0o700 });
  const dir = join(base, "secrets-backup");
  // 이전 실행이 지우지 못하고 남긴 옮긴 폴더가 있으면 먼저 지운다(백업 내용이 들어 있을 수 있다).
  for (const name of readdirSync(base)) if (name.startsWith(STALE)) removeStale(join(base, name), ops);
  let st: ReturnType<typeof lstatSync> | undefined;
  try {
    st = lstatSync(dir);
  } catch {
    st = undefined;
  }
  // 심볼릭 링크면 chmod가 링크 너머를 바꾸고 백업은 다른 곳에 쌓인다. lstat이라 링크는 폴더가 아니다(따라가지 않고 멈춘다).
  if (st && !st.isDirectory()) throw new CliError("Infisical 백업 경로가 폴더가 아니다(심볼릭 링크 포함)", NEXT);
  if (!st) ops.mkdirLocked(dir);
  else if (entries(dir).length > 0) replaceLocked(base, dir, ops);
  // 비어 있으면 열지 않고 권한만 좁힌다(좁히는 쪽은 틈을 만들지 않는다). 이미 잠긴 폴더는 그대로 둔다.
  else if ((statSync(dir).mode & 0o222) !== 0) chmodSync(dir, 0o500);
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

// infisical 호출 하나를 감싼다. run은 실제 HOME을 받아 자식의 HOME으로 쓴다. 호출 전 준비(처음 한 번),
// 호출 뒤 파일 0개 확인. 생겼으면 백업 경로를 잠긴 새 폴더로 바꾸고(지우기) 실패한다.
export function guardInfisicalBackup<T>(home: string | undefined, run: (realHome: string) => T, ops: BackupOps = realOps): T {
  const real = realHome(home);
  const dir = join(real, ".infisical", "secrets-backup");
  if (!prepared.has(dir)) {
    prepare(real, ops);
    prepared.add(dir);
  }
  try {
    return run(real);
  } finally {
    if (entries(dir).length !== 0) {
      // 같은 실행의 다음 조회도 처음부터 다시 준비하게 한다.
      prepared.delete(dir);
      replaceLocked(join(real, ".infisical"), dir, ops);
      // 백업이 생긴 호출의 결과는 쓰지 않는다(호출 자체의 오류보다 이 실패가 앞선다).
      throw new CliError("Infisical 백업 파일이 생겼다. 지우고 중단한다", NEXT);
    }
  }
}

// 시험 전용: 준비 기록을 비운다(cli/test/setup.ts).
export function resetBackupGuardForTests(): void {
  prepared.clear();
}
