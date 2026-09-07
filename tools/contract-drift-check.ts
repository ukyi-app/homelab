// 동봉 계약(vendored 사본) 드리프트 리컨실러. homelab SSOT ↔ 다운스트림 사본 정규화 diff.
// alert-and-report: 하드 실패 아님 — {drift, errors, roster} JSON 출력, contract-drift.yaml이 telegram 알림.
// 라이브 raw fetch는 이 CLI의 **기본 모드에서만**(게이트 bats는 오프라인 모드만 검증).
//
// 모드 넷:
//   (기본)        라이브 fetch + 정규화 diff + 로스터 대조 → JSON
//   --self-test   순수 함수 유닛(정규화·분류·로스터) — 이름 있는 케이스 목록, 오프라인
//   --roster      로스터 대조만(오프라인) — 앱 파생 집합 ↔ 매니페스트 앱 target 등식
//   --checklist   변경 파일 목록 ∩ 매니페스트 source → 다운스트림 전파 체크리스트(오프라인)
import { existsSync, readFileSync } from "node:fs";
import { listUnits } from "./lib/repo-walk.ts";

export type Norm = "typescript" | "exact";
type Target = { repo: string; ref: string; path: string; normalize: Norm };
type Entry = { source: string; targets: Target[] };
// scaffoldRepos = **앱이 아닌** 대상(템플릿 레포). 로스터 등식에서 제외된다 —
// 선언 축이 없으면 템플릿 행이 매 실행 stale로 잡힌다.
export type Manifest = { owner: string; scaffoldRepos?: string[]; vendored: Entry[] };

// ── 정규화 ────────────────────────────────────────────────────────────────────
// 줄 주석 제거를 **공백 축약보다 먼저** 한다. 종전엔 `\s+` 축약이 개행까지 지워
// `// foo\nbar();`와 `// foo bar();`가 둘 다 `//foobar();`가 됐다 — 전자는 bar()가 실행되고
// 후자는 주석이다. 즉 **코드가 주석 줄로 옮겨간 사본이 동일로 읽혔다**(가장 위험한 방향).
// ⚠️ 이 방식의 대가 둘, 둘 다 의도한 트레이드다:
//   (1) 주석 **문구만** 다른 사본은 더는 드리프트가 아니다. 벤더 계약의 대상은 코드이고,
//       포매터/산문 드리프트로 주간 알림이 울면 유일한 정보성 채널이 학습된 무시로 죽는다.
//   (2) 문자열 리터럴 안의 `//`(예: URL)도 잘린다. 원본·사본에 **대칭**으로 적용되므로 거짓
//       드리프트는 안 나지만, 그 `//` 뒤의 실드리프트는 마스킹된다. 현 SSOT 2건에는 문자열
//       내부 `//`가 0건이다(실측) — 생기면 블록 주석 인식 파서로 승격할 자리다.
const stripLineComments = (s: string) => s.replace(/\/\/[^\n]*/g, "");
// exact=CRLF만 통일(그 외 바이트 일치), typescript=줄 주석 제거 + 공백 + 닫는 괄호/브레이스/
// 대괄호 앞의 trailing ;/, 만 제거.
// ⚠️ 공백-only로는 부족(prettier가 멀티라인 리터럴 마지막 멤버에 trailing ;/, 를 붙임 — 라이브 실측: trip-mate
//    사본이 `out?: string; }` vs SSOT `out?: string }`로 세미콜론 1개만 달랐다). 반대로 ;/, 전면 제거나 "줄끝
//    기준" 제거는 과함/버그다: 전면 제거는 문자열 내부 `join(", ")`↔`join(";")` 실드리프트를 마스킹하고, 줄끝($)
//    기준은 멀티라인의 멤버 세미콜론(줄끝)을 단일라인(mid-line)과 비대칭 제거해 거짓 드리프트를 낸다. 그래서
//    "닫는 구분자 바로 앞" 위치의 trailing 만 제거하고 내부 ;/, 는 보존한다(실식별자/문자열/구분자 드리프트는 검출).
export const normalize = (s: string, mode: Norm) =>
  mode === "exact"
    ? s.replace(/\r\n/g, "\n")
    : stripLineComments(s).replace(/[;,](?=\s*[)\]}])/g, "").replace(/\s+/g, "");

// ── errors 사유 축 ────────────────────────────────────────────────────────────
// 종전엔 404(경로 리네임·레포 삭제·private 전환)와 5xx·타임아웃이 같은 배열에 섞여
// "transient 가능 — 재확인" 한 문구로 나갔다. 상태가 run 사이에 남지 않으므로
// '3주 연속 같은 404'와 '이번 주 망 블립'이 구별되지 않았다.
// ⚠️ 사유 축만 준다 — drift로 **승격하지 않는다**. 비인증 raw fetch에서 삭제·private 전환·
//    경로 리네임은 원리적으로 구별 불가라, 승격하면 앱 레포를 private으로 돌린 정상 조치가
//    파괴적 드리프트 신호로 나간다. 판별은 사람이 하고 게이트는 사유만 실어 보낸다.
export type ErrReason = "absent-or-private" | "transient";
export const classifyStatus = (status: number): ErrReason =>
  status === 404 || status === 403 ? "absent-or-private" : "transient";

// ── 로스터 대조 ───────────────────────────────────────────────────────────────
// 앱 축의 권위는 매니페스트의 손 열거가 아니라 **인레포 파생원**이다:
// `apps/<app>/deploy/prod/source-repo`(외부 레포 바인딩). apps.json 파생보다 정확하다 —
// internal(비공개) 앱도 source-repo를 갖지만 apps.json에는 없다.
export type Roster = {
  status: "greenfield" | "matched" | "mismatch";
  derived: string[]; declared: string[]; missing: string[]; stale: string[];
};

// 열거는 공유 워커의 `apps` 유닛 스코프가 소유한다(제외 어휘의 사본을 두지 않는다).
// source-repo가 없는 유닛은 **인레포 앱**이라 벤더 사본 대상이 아니다 — 조용한 제외가 아니라
// 정의상 비대상이다(벤더 계약은 외부 앱 레포의 사본만 감시한다).
export function deriveAppRepos(root: string): string[] {
  const out = new Set<string>();
  for (const u of listUnits("apps", root)) {
    const p = `${root}/${u.dir}/deploy/prod/source-repo`;
    if (!existsSync(p)) continue;
    const s = readFileSync(p, "utf8").trim();
    if (s.length === 0) continue;
    out.add(s.slice(s.lastIndexOf("/") + 1));
  }
  return [...out].sort();
}

// ⚠️ 등식이다, ⊇가 아니다. 초과(철거된 레포가 매니페스트에 남음)도 드리프트다 — 실질 대상이
// 1건인데 알림이 3건으로 보고되면 그 게이트가 자기 임계를 올린다(page·trip-mate-api 실측).
export function reconcileRoster(derived: string[], declaredAll: string[], scaffold: string[]): Roster {
  const scaf = new Set(scaffold);
  const declared = [...new Set(declaredAll.filter((r) => !scaf.has(r)))].sort();
  const dset = new Set(derived);
  const dcl = new Set(declared);
  const missing = derived.filter((r) => !dcl.has(r));
  const stale = declared.filter((r) => !dset.has(r));
  const status: Roster["status"] =
    missing.length + stale.length > 0 ? "mismatch" : derived.length === 0 ? "greenfield" : "matched";
  return { status, derived, declared, missing, stale };
}

// ── 다운스트림 전파 체크리스트(오프라인) ────────────────────────────────────
// PR 시점 신호를 **라이브 대조로 두지 않는 이유**: SSOT를 편집하는 PR에서는 drift>0이 정상
// 상태다(사본은 아직 옛 바이트다). 라이브 대조를 PR에 걸면 상시 red가 되고, 그 red는 곧
// 무시된다. 그래서 신호를 "변경 파일 ∩ 매니페스트 source"의 정적 교집합으로 낸다 —
// 네트워크 0, 판정 0, **해야 할 일의 목록**만.
export type ChecklistRow = { source: string; repo: string; ref: string; path: string };
export function downstreamChecklist(mf: Manifest, changed: string[]): ChecklistRow[] {
  const touched = new Set(changed.map((c) => c.trim()).filter((c) => c.length > 0));
  const rows: ChecklistRow[] = [];
  for (const e of mf.vendored) {
    if (!touched.has(e.source)) continue;
    for (const t of e.targets) rows.push({ source: e.source, repo: t.repo, ref: t.ref, path: t.path });
  }
  return rows;
}

// ── self-test: 이름 있는 케이스 목록 ─────────────────────────────────────────
// 종전엔 단일 boolean(`const ok = A && B && …`)이라 케이스가 사라져도 rc 0이었고, 실패했을 때
// **어느 케이스인지** 알 수 없었다. 이름을 붙이고 개수를 방출한다(호출부가 바닥값을 잰다).
type Case = { name: string; ok: () => boolean };
const CASES: Case[] = [
  // 멀티라인 type 리터럴(prettier) === 단일라인(compact): 닫는 } 앞 trailing ; 흡수 + 공백 무시 (trip-mate 실측 케이스)
  { name: "ts:formatter-multiline-eq-compact", ok: () =>
    normalize("type A = {\n  a: string;\n  b: string;\n};", "typescript") === normalize("type A = { a: string; b: string };", "typescript") },
  { name: "ts:trailing-comma-absorbed", ok: () => normalize("[1, 2, 3,]", "typescript") === normalize("[1, 2, 3]", "typescript") },
  { name: "ts:real-drift-detected", ok: () => normalize("const a = 1", "typescript") !== normalize("const a = 2", "typescript") },
  { name: "ts:inner-separator-preserved", ok: () => normalize('a.join(", ")', "typescript") !== normalize('a.join(";")', "typescript") },
  // (d) 주석/코드 경계 — 개행 소거가 지우던 축. `b();`가 실행되는 사본과 주석인 사본은 달라야 한다.
  { name: "ts:comment-code-boundary", ok: () => normalize("// a\nb();", "typescript") !== normalize("// a b();", "typescript") },
  { name: "ts:comment-only-drift-ignored", ok: () => normalize("// 옛 문구\nb();", "typescript") === normalize("// 새 문구\nb();", "typescript") },
  { name: "exact:crlf-normalized", ok: () => normalize("AAAA\r\nBBBB\n", "exact") === "AAAA\nBBBB\n" },
  { name: "exact:byte-drift-detected", ok: () => normalize("AAAA\nBBBB\n", "exact") !== normalize("AAAAx\nBBBB\n", "exact") },
  // (c) 상태코드 분류 — 부재/접근불가 vs 전송 실패.
  { name: "classify:404-absent", ok: () => classifyStatus(404) === "absent-or-private" },
  { name: "classify:403-absent", ok: () => classifyStatus(403) === "absent-or-private" },
  { name: "classify:503-transient", ok: () => classifyStatus(503) === "transient" },
  { name: "classify:500-transient", ok: () => classifyStatus(500) === "transient" },
  // (a) 로스터 등식 — 초과도 부족도 mismatch, 공집합은 greenfield(통과가 아니라 상태).
  { name: "roster:stale-target", ok: () => reconcileRoster([], ["tpl", "ghost"], ["tpl"]).status === "mismatch" },
  { name: "roster:missing-target", ok: () => reconcileRoster(["orders"], ["tpl"], ["tpl"]).missing.join(",") === "orders" },
  { name: "roster:matched", ok: () => reconcileRoster(["orders"], ["tpl", "orders"], ["tpl"]).status === "matched" },
  { name: "roster:greenfield", ok: () => reconcileRoster([], ["tpl"], ["tpl"]).status === "greenfield" },
];

const arg = (k: string, d: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };

if (import.meta.main) {
  if (process.argv.includes("--self-test")) {
    // `--self-test-mutate`는 **러너의 양성 대조 전용**이다 — 케이스 하나를 강제로 뒤집어
    // "rc 0"이 "케이스가 하나도 안 돌았다"와 구별됨을 증명한다(게이트 bats가 밟는다).
    const mutate = process.argv.includes("--self-test-mutate");
    const cases = mutate ? [...CASES, { name: "mutation-witness", ok: () => false }] : CASES;
    for (const c of cases) {
      if (!c.ok()) { process.stderr.write(`SELFTEST FAIL: ${c.name}\n`); process.exit(1); }
    }
    process.stdout.write(`SELFTEST: ${cases.length} cases ok\n`);
    process.exit(0);
  }

  const mf: Manifest = JSON.parse(readFileSync(arg("--manifest", "tools/vendored-contract.json"), "utf8"));

  if (process.argv.includes("--checklist")) {
    const changedFile = arg("--changed", "");
    if (changedFile === "") { process.stderr.write("--checklist에는 --changed <파일>(줄당 경로 하나)이 필요하다\n"); process.exit(2); }
    const rows = downstreamChecklist(mf, readFileSync(changedFile, "utf8").split("\n"));
    process.stdout.write("## 다운스트림 전파 체크리스트 (벤더 계약 SSOT)\n\n");
    if (rows.length === 0) {
      // ⚠️ 0건은 **통과가 아니라 상태**다 — 아무 줄도 안 내면 "체커가 죽었다"와 구별되지 않는다.
      process.stdout.write("대상 0건 — 이 PR은 벤더 계약 SSOT(매니페스트 `source`)를 만지지 않는다.\n");
    } else {
      for (const r of rows) process.stdout.write(`- [ ] \`${mf.owner}/${r.repo}\` @ ${r.ref} — \`${r.path}\` (SSOT: \`${r.source}\`)\n`);
      process.stdout.write(`\n대상 ${rows.length}건 — 다운스트림 사본에 같은 변경을 전파해야 한다(SSOT→사본 방향).\n`);
    }
    process.exit(0);
  }

  const root = arg("--root", ".");
  const declaredRepos = mf.vendored.flatMap((e) => e.targets.map((t) => t.repo));
  const roster = reconcileRoster(deriveAppRepos(root), declaredRepos, mf.scaffoldRepos ?? []);
  // 사람이 읽는 채널에도 한 줄 — 0건이 로그에서 침묵으로 보이지 않게 한다.
  process.stderr.write(
    roster.status === "greenfield"
      ? "ROSTER: 파생 앱 0건(그린필드) — 매니페스트 앱 target도 0건이라 등식은 성립하지만 판별력은 0이다.\n"
      : `ROSTER: ${roster.status} — 파생 ${roster.derived.length}건 · 선언 ${roster.declared.length}건 · 누락 ${roster.missing.length} · 잔재 ${roster.stale.length}\n`,
  );

  const drift: unknown[] = [];
  const errors: unknown[] = [];
  // 로스터 불일치는 errors가 아니라 **drift**다 — 로스터가 어긋나 있다는 사실 자체가 첫 발화다.
  for (const r of roster.missing) drift.push({ kind: "roster", reason: "missing-target", repo: r });
  for (const r of roster.stale) drift.push({ kind: "roster", reason: "stale-target", repo: r });

  if (!process.argv.includes("--roster")) {
    const raw = (o: string, t: Target) => `https://raw.githubusercontent.com/${o}/${t.repo}/${t.ref}/${t.path}`;
    for (const e of mf.vendored) {
      const src = readFileSync(e.source, "utf8");
      for (const t of e.targets) {
        const url = raw(mf.owner, t);
        try {
          const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
          if (!res.ok) { errors.push({ url, status: res.status, reason: classifyStatus(res.status) }); continue; }
          const remote = await res.text();
          if (normalize(src, t.normalize) !== normalize(remote, t.normalize))
            drift.push({ source: e.source, repo: t.repo, path: t.path });
        } catch (err) {
          // 예외 경로는 전송 실패다(타임아웃·DNS·TLS) — 상태코드가 없으므로 분류할 축이 없다.
          errors.push({ url, error: String(err), reason: "transient" satisfies ErrReason });
        }
      }
    }
  }
  process.stdout.write(JSON.stringify({ drift, errors, roster }, null, 2) + "\n");
}
